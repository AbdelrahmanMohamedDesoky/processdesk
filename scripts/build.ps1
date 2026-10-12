param([Parameter(Mandatory)][string]$UpstreamSha, [string]$RecipeHash = '', [switch]$Baseline)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $root 'branding.json') -Raw | ConvertFrom-Json
if ($UpstreamSha -notmatch '^[a-f0-9]{40}$') { throw 'A full upstream commit is required.' }
$work = Join-Path $root '.work'
$source = Join-Path $work 'source'
$dist = Join-Path $root 'dist'
$payload = Join-Path $work 'payload'
foreach ($path in @($source, $dist, $payload)) {
    if (Test-Path -LiteralPath $path) { throw "Build directory already exists: $path. Use a clean checkout." }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}
function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
}
Invoke-Native git @('-C', $source, 'init', '--quiet')
Invoke-Native git @('-C', $source, 'remote', 'add', 'origin', "https://github.com/$($config.upstream_repository).git")
Invoke-Native git @('-C', $source, 'fetch', '--depth=1', 'origin', $UpstreamSha)
Invoke-Native git @('-C', $source, 'checkout', '--detach', 'FETCH_HEAD')
$actual = (& git -C $source rev-parse HEAD).Trim()
if ($actual -ne $UpstreamSha) { throw 'Source revision mismatch.' }
$commitTime = [DateTimeOffset]::FromUnixTimeSeconds([long](& git -C $source show -s --format=%ct HEAD))
$buildNumber = [int]$env:GITHUB_RUN_NUMBER
if ($buildNumber -lt 1 -or $buildNumber -gt 65535) { throw 'Build number must fit a native file-version component.' }
$buildDate = ($commitTime.UtcDateTime.Year % 100) * 1000 + $commitTime.UtcDateTime.DayOfYear
$version = "$($config.version_major).$($config.version_minor).$buildDate.$buildNumber"
& (Join-Path $PSScriptRoot 'apply-branding.ps1') -Source $source -Version $version -Baseline:$Baseline
if (!$Baseline) {
    Invoke-Native magick @((Join-Path $root 'assets/app.svg'), '-background', 'none', '-define', 'icon:auto-resize=256,64,48,32,24,16', (Join-Path $source 'SystemInformer/SystemInformer.ico'))
    Copy-Item -LiteralPath (Join-Path $source 'SystemInformer/SystemInformer.ico') -Destination (Join-Path $source 'SystemInformer/resources/application.ico') -Force
    Invoke-Native magick @((Join-Path $root 'assets/app.svg'), (Join-Path $source 'SystemInformer/resources/SystemInformer.png'))
    $sourcePatch = (& git -C $source diff --no-ext-diff --binary) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot record icon and source changes.' }
    [IO.File]::WriteAllText((Join-Path $source 'branding.patch'), $sourcePatch + "`n", [Text.UTF8Encoding]::new($false))
}

# Use the hosted compiler environment without installing anything on the user's PC.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (!$vs) { throw 'Visual C++ compiler is not installed on the runner.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
$environment = & cmd.exe /d /c ('"' + $vcvars + '" amd64 >nul && set')
if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the compiler environment.' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
Push-Location $source
try {
    # Only the host build tool is needed, rather than all architectures and Debug builds.
    Invoke-Native dotnet @('publish', 'tools/CustomBuildTool/CustomBuildTool.csproj', '-c', 'Release', '-p:Platform=x64', '-p:PublishAot=false', '-p:PublishTrimmed=false', '-p:PublishSingleFile=false', '-o', 'tools/CustomBuildTool/bin/Release/amd64')
    $customTool = Join-Path $source 'tools/CustomBuildTool/bin/Release/amd64/CustomBuildTool.exe'
    Invoke-Native $customTool @('-write-tools-id')
    Invoke-Native cmake @('-S', '.', '-B', 'build-processdesk', '-G', 'Ninja', '--toolchain', 'cmake/toolchain/msvc-amd64.cmake', '-DCMAKE_BUILD_TYPE=Release', '-DSI_WITH_CORE=ON', '-DSI_WITH_PLUGINS=ON', '-DSI_WITH_KERNEL=OFF', '-DSI_WITH_WPP_USER=OFF')
    $targets = @('SystemInformer') + @($config.plugins)
    Invoke-Native cmake (@('--build', 'build-processdesk', '--parallel', '2', '--target') + $targets)
} finally { Pop-Location }
if ($Baseline) { Write-Host 'Hosted baseline build succeeded.'; return }
$output = Join-Path $source 'bin-cmake/Release64'
$exe = Join-Path $output "$($config.app_id).exe"
if (!(Test-Path -LiteralPath $exe)) { throw 'Expected branded executable is missing.' }
$info = (Get-Item -LiteralPath $exe).VersionInfo
if ($info.ProductName -ne $config.display_name -or $info.FileDescription -ne $config.display_name -or $info.OriginalFilename -ne "$($config.app_id).exe" -or $info.FileVersion -ne $version -or $info.CompanyName -ne $config.publisher) { throw 'Compiled application metadata does not match the configured brand.' }
Copy-Item -LiteralPath $exe -Destination $payload
New-Item -ItemType Directory -Path (Join-Path $payload 'plugins'), (Join-Path $payload 'Resources') -Force | Out-Null
foreach ($plugin in $config.plugins) {
    $pluginFile = Join-Path $output "plugins/$plugin.dll"
    if (!(Test-Path -LiteralPath $pluginFile)) { throw "Missing plugin: $plugin" }
    Copy-Item -LiteralPath $pluginFile -Destination (Join-Path $payload 'plugins')
}
foreach ($resource in @('capslist.txt', 'etwguids.txt', 'pooltag.txt', 'settings.schema.json')) {
    Copy-Item -LiteralPath (Join-Path $source "SystemInformer/resources/$resource") -Destination (Join-Path $payload 'Resources')
}
foreach ($name in @('LICENSE.txt', 'COPYRIGHT.txt')) {
    if (Test-Path (Join-Path $source $name)) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination $payload }
}
# Preserve third-party notices with the distribution.
$notices = Join-Path $payload 'Licenses'
New-Item -ItemType Directory -Path $notices -Force | Out-Null
foreach ($file in Get-ChildItem (Join-Path $source 'tools/thirdparty') -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE|COPYRIGHT)(\.|$)' }) {
    $relative = [IO.Path]::GetRelativePath((Join-Path $source 'tools/thirdparty'), $file.FullName)
    $destination = Join-Path $notices $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination
}
$debugger = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/Debuggers/x64'
foreach ($dll in @('dbghelp.dll', 'dbgcore.dll', 'symsrv.dll')) {
    if (Test-Path (Join-Path $debugger $dll)) { Copy-Item -LiteralPath (Join-Path $debugger $dll) -Destination $payload }
}
# Generate a small neutral icon from the source SVG using the runner's existing tool.
Copy-Item -LiteralPath (Join-Path $source 'SystemInformer/SystemInformer.ico') -Destination (Join-Path $payload 'Resources/app.ico')
Copy-Item -LiteralPath (Join-Path $source 'SystemInformer/resources/SystemInformer.png') -Destination (Join-Path $payload 'Resources/icon.png')
if (@(Get-ChildItem $payload -Recurse -File -Filter '*.sys').Count -ne 0 -or (Test-Path (Join-Path $payload 'plugins/Updater.dll'))) { throw 'Unexpected driver or upstream updater in the package.' }

$manifest = [ordered]@{
    name = $config.display_name; app_id = $config.app_id; version = $version
    upstream_repository = $config.upstream_repository; upstream_sha = $UpstreamSha
    upstream_commit_time = $commitTime.ToString('o'); recipe_hash = $RecipeHash
    pipeline_sha = $env:GITHUB_SHA; pipeline_run = $env:GITHUB_RUN_ID
    built_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); architecture = 'x64'
    kernel_driver_enabled = $false; authenticode_signed = $false
    plugins = $config.plugins; runner_image = $env:ImageVersion
    cmake = (& cmake --version | Select-Object -First 1); dotnet = (& dotnet --version)
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $payload 'build-manifest.json') -Encoding utf8NoBOM
Copy-Item -LiteralPath (Join-Path $source 'branding.patch') -Destination $dist
Copy-Item -LiteralPath (Join-Path $payload 'build-manifest.json') -Destination $dist
Copy-Item -LiteralPath (Join-Path $source 'LICENSE.txt') -Destination (Join-Path $dist 'UPSTREAM-LICENSE.txt')
$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
Invoke-Native $iscc @("/DAppName=$($config.display_name)", "/DAppIdName=$($config.app_id)", "/DAppVersion=$version", "/DPublisher=$($config.publisher)", "/DRepositoryURL=https://github.com/$($config.repository)", "/DPayload=$payload", "/DOutput=$dist", (Join-Path $root 'packaging/installer.iss'))
$zip = Join-Path $dist "$($config.app_id)-$version-x64-portable.zip"
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -CompressionLevel Optimal
& (Join-Path $PSScriptRoot 'smoke-test.ps1') -Installer (Join-Path $dist "$($config.app_id)-$version-x64-setup.exe") -ExpectedExecutable $exe -Version $version -Report (Join-Path $dist 'validation.json')
$files = @(Get-ChildItem $dist -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' })
$checksums = foreach ($file in $files) { "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($file.Name)" }
$checksums | Set-Content (Join-Path $dist 'SHA256SUMS.txt') -Encoding utf8NoBOM
"Built and validated $($config.display_name) $version from $UpstreamSha." | Write-Host
