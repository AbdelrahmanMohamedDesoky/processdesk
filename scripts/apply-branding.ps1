param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Version, [switch]$Baseline)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $root 'branding.json') -Raw | ConvertFrom-Json
if ($config.app_id -notmatch '^[A-Za-z][A-Za-z0-9]{2,39}$' -or $config.display_name -notmatch '^[A-Za-z][A-Za-z0-9 ]{2,59}$' -or $config.publisher -notmatch '^[A-Za-z][A-Za-z0-9 .-]{2,79}$') { throw 'Branding must use simple ASCII names.' }
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Invalid native file version.' }
$utf8 = [Text.UTF8Encoding]::new($false)
function Replace-Contract([string]$Relative, [string]$Before, [string]$After, [int]$Count = 1) {
    $path = Join-Path $Source $Relative
    $text = [IO.File]::ReadAllText($path)
    $actual = [regex]::Matches($text, [regex]::Escape($Before)).Count
    if ($actual -ne $Count) { throw "Upstream contract changed: $Relative (expected $Count occurrences, found $actual)." }
    [IO.File]::WriteAllText($path, $text.Replace($Before, $After), $utf8)
}
# Fail visibly if upstream changes these critical boundaries.
Replace-Contract 'SystemInformer/main.c' 'PhEnableKsiSupport = !!PhGetIntegerSetting(SETTING_KSI_ENABLE) && !PhStartupParameters.NoKph && !PhIsExecutingInWow64();' 'PhEnableKsiSupport = FALSE; // Application-only distribution; do not connect to or load a kernel driver.'
Replace-Contract 'plugins/CMakeLists.txt' 'add_subdirectory(Updater)' '# Upstream installer updater excluded from this distribution.'
Replace-Contract 'plugins/CMakeLists.txt' 'add_subdirectory(AgentTools)' '# Optional remote agent integration excluded from this distribution.'
if (!$Baseline) {
    Replace-Contract 'SystemInformer/CMakeLists.txt' 'set_target_properties(SystemInformer PROPERTIES ENABLE_EXPORTS TRUE)' "set_target_properties(SystemInformer PROPERTIES ENABLE_EXPORTS TRUE OUTPUT_NAME $($config.app_id))"
    Replace-Contract 'SystemInformer/settings.c' 'PhpAddStringSetting(SETTING_MAIN_WINDOW_CLASS_NAME, L"MainWindowClassName");' "PhpAddStringSetting(SETTING_MAIN_WINDOW_CLASS_NAME, L`"$($config.app_id)MainWindow`" );"
    foreach ($file in @('SystemInformer.exe', 'SystemInformer.lib', 'SystemInformer.pdb')) {
        $path = Join-Path $Source 'tools/CustomBuildTool/Build.cs'
        $text = [IO.File]::ReadAllText($path)
        if (!$text.Contains($file)) { throw "Upstream build filename contract changed: $file" }
        [IO.File]::WriteAllText($path, $text.Replace($file, $file.Replace('SystemInformer', $config.app_id)), $utf8)
    }
    # Change user-facing string literals; retain source symbols, APIs, and copyright comments.
    foreach ($dir in @('SystemInformer', 'phlib', 'plugins')) {
        foreach ($file in Get-ChildItem (Join-Path $Source $dir) -Recurse -File | Where-Object { $_.Extension -in '.c', '.cpp', '.h', '.rc', '.manifest' }) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $updated = [regex]::Replace($text, 'L?"(?:\\.|[^"\\])*"', [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                $literal = $match.Value
                if ($literal -match 'Copyright|copyright|All rights reserved') { return $literal }
                return $literal.Replace('System Informer', $config.display_name)
            })
            if ($file.Extension -eq '.manifest') { $updated = $updated.Replace('<description>System Informer</description>', "<description>$($config.display_name)</description>") }
            if ($updated -ne $text) { [IO.File]::WriteAllText($file.FullName, $updated, $utf8) }
        }
    }
    # Separate settings and application object namespaces from the stock installation.
    foreach ($relative in @('phlib/util.c', 'phlib/settings.c', 'SystemInformer/main.c')) {
        $path = Join-Path $Source $relative
        $text = [IO.File]::ReadAllText($path)
        $updated = $text.Replace('\\SystemInformer\\', "\\$($config.app_id)\\").Replace('Software\\SystemInformer', "Software\\$($config.app_id)").Replace('\\BaseNamedObjects\\SystemInformer', "\\BaseNamedObjects\\$($config.app_id)").Replace('L"\\SystemInformer"', "L`"\\$($config.app_id)`"")
        [IO.File]::WriteAllText($path, $updated, $utf8)
    }
    $versionPath = Join-Path $Source 'SystemInformer/version.rc'
    $text = [IO.File]::ReadAllText($versionPath)
    $text = [regex]::Replace($text, 'VALUE "CompanyName", "[^"]+"', "VALUE `"CompanyName`", `"$($config.publisher)`"")
    $text = [regex]::Replace($text, 'VALUE "OriginalFilename", "[^"]+"', "VALUE `"OriginalFilename`", `"$($config.app_id).exe`"")
    [IO.File]::WriteAllText($versionPath, $text, $utf8)
    $text = [IO.File]::ReadAllText((Join-Path $Source 'SystemInformer/SystemInformer.manifest'))
    if (!$text.Contains("name=`"$($config.display_name)`"")) { throw 'Manifest branding failed.' }
}
# CMake needs native file-version macros, independently of upstream release tooling.
$parts = $Version.Split('.')
$sha = (& git -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[a-f0-9]{40}$') { throw 'Invalid source commit.' }
$cmakePath = Join-Path $Source 'CMakeLists.txt'
$text = [IO.File]::ReadAllText($cmakePath)
$definitions = "`nadd_compile_definitions(PHAPP_VERSION_MAJOR=$($parts[0]) PHAPP_VERSION_MINOR=$($parts[1]) PHAPP_VERSION_BUILD=$($parts[2]) PHAPP_VERSION_REVISION=$($parts[3]) PHAPP_VERSION_COMMITHASH=$sha)`n"
if (!$text.Contains('project(SystemInformer)')) { throw 'Upstream CMake project contract changed.' }
[IO.File]::WriteAllText($cmakePath, $text.Replace('project(SystemInformer)', "project(SystemInformer)$definitions"), $utf8)
# No signature is generated or claimed for this user-mode-only distribution.
$toolsPath = Join-Path $Source 'cmake/tools.cmake'
$toolsText = [IO.File]::ReadAllText($toolsPath)
$pattern = '(?s)function\(si_kphsign target\).*?endfunction\(\)'
if ([regex]::Matches($toolsText, $pattern).Count -ne 1) { throw 'Upstream CMake signing hook contract changed.' }
[IO.File]::WriteAllText($toolsPath, [regex]::Replace($toolsText, $pattern, 'function(si_kphsign target)' + "`n    # Unsigned application-only build; the driver trust policy is unchanged.`nendfunction()"), $utf8)
# An auditable patch is included with every release.
$diff = (& git -C $Source diff --no-ext-diff --binary) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Cannot generate source patch.' }
[IO.File]::WriteAllText((Join-Path $Source 'branding.patch'), $diff + "`n", $utf8)
Write-Host "Applied $(if ($Baseline) {'baseline application-only'} else {$config.display_name}) build recipe at $sha."
