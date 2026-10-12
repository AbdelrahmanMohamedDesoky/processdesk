param([Parameter(Mandatory)][string]$Installer, [Parameter(Mandatory)][string]$ExpectedExecutable, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Report)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Installer smoke tests run only on the disposable GitHub runner.' }
$root = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $root 'branding.json') -Raw | ConvertFrom-Json
$installDir = Join-Path $env:RUNNER_TEMP "$($config.app_id)-installer-validation"
if (Test-Path -LiteralPath $installDir) { throw 'Installer test directory already exists.' }
$driverBefore = @(Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'KSystemInformer|KProcessHacker' -and $_.State -eq 'Running' } | Select-Object -ExpandProperty Name)
$resourceHeader = Get-Content (Join-Path $root '.work/source/SystemInformer/resource.h') -Raw
$exitMatch = [regex]::Match($resourceHeader, '(?m)^#define\s+ID_HACKER_EXIT\s+(\d+)\s*$')
if (!$exitMatch.Success) { throw 'Cannot identify the application Exit command.' }
$exitCommand = [int]$exitMatch.Groups[1].Value
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ProcessDeskValidationNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int capacity);
}
'@
function Run-Setup([string]$Path, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    if (!$process.WaitForExit(120000)) { $process.Kill(); throw 'Installer test timed out.' }
    if ($process.ExitCode -ne 0) { throw "Installer test failed: exit $($process.ExitCode)" }
}
$setupArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $installDir + '"'))
Run-Setup $Installer $setupArgs
$installedExe = Join-Path $installDir "$($config.app_id).exe"
$expectedHash = (Get-FileHash -LiteralPath $ExpectedExecutable).Hash
if ((Get-FileHash -LiteralPath $installedExe).Hash -ne $expectedHash) { throw 'Installed executable differs from the validated build.' }
$process = Start-Process -FilePath $installedExe -ArgumentList '-nosettings' -PassThru
$title = ''
$loadedPlugins = @()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Application exited during launch: $($process.ExitCode)" }
        $title = $process.MainWindowTitle
    } while (!$title.StartsWith($config.display_name) -and [DateTime]::UtcNow -lt $deadline)
    if (!$title.StartsWith($config.display_name) -or !$process.Responding) { throw "Branded main window did not become ready (title: $title)." }
    $windowClass = [Text.StringBuilder]::new(256)
    [void][ProcessDeskValidationNative]::GetClassName($process.MainWindowHandle, $windowClass, $windowClass.Capacity)
    if ($windowClass.ToString() -ne "$($config.app_id)MainWindow") { throw "An unexpected startup window intercepted validation: $title / $windowClass" }
    $loadedPlugins = @($process.Modules | Where-Object { $_.FileName.StartsWith((Join-Path $installDir 'plugins'), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -ExpandProperty ModuleName)
    foreach ($plugin in $config.plugins) { if ("$plugin.dll" -notin $loadedPlugins) { throw "Plugin did not load: $plugin" } }
    if (![ProcessDeskValidationNative]::PostMessage($process.MainWindowHandle, 0x0111, [IntPtr]$exitCommand, [IntPtr]::Zero)) { throw 'Cannot request application Exit.' }
    if (!$process.WaitForExit(15000)) { throw 'Application did not close normally.' }
} finally {
    if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
}
# Exercise an existing installation, then its uninstaller.
Run-Setup $Installer $setupArgs
if ((Get-FileHash -LiteralPath $installedExe).Hash -ne $expectedHash) { throw 'Upgrade changed the executable unexpectedly.' }
Run-Setup (Join-Path $installDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
if (Test-Path -LiteralPath $installedExe) { throw 'Uninstaller left the application executable behind.' }
$driverAfter = @(Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'KSystemInformer|KProcessHacker' -and $_.State -eq 'Running' } | Select-Object -ExpandProperty Name)
if ((($driverBefore | Sort-Object) -join ',') -cne (($driverAfter | Sort-Object) -join ',')) { throw 'Driver state changed during application validation.' }
@{ install = 'passed'; existing_install_upgrade = 'passed'; uninstall = 'passed'; application_launch = 'passed'; title = $title; window_class = $windowClass.ToString(); loaded_plugins = $loadedPlugins; native_version = $Version; driver_state_unchanged = $true; game_compatibility = 'not tested' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding utf8NoBOM
