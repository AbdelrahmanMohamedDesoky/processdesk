param([string]$UpstreamRef = '', [switch]$Force)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $root 'branding.json') -Raw | ConvertFrom-Json
if (!$UpstreamRef) { $UpstreamRef = $config.upstream_ref }
if ($UpstreamRef -notmatch '^[A-Za-z0-9._/-]+$') { throw 'Invalid upstream reference.' }
$sha = (& gh api "repos/$($config.upstream_repository)/commits/$UpstreamRef" --jq .sha).Trim()
if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[a-f0-9]{40}$') { throw 'Cannot resolve upstream commit.' }
$recipe = $env:RECIPE_HASH
if ($recipe -notmatch '^[a-f0-9]{64}$') { throw 'Missing workflow recipe hash.' }
$tag = "pd-$($sha.Substring(0, 12))-$($recipe.Substring(0, 12))"
$repo = $env:GITHUB_REPOSITORY
if ($repo -ne $config.repository) { throw "Publishing is confined to $($config.repository)." }
$headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$exists = $false
try {
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$tag" -Headers $headers
    if ($release.draft) { throw 'An incomplete draft exists for this build. Inspect it before retrying.' }
    $exists = $true
} catch {
    if (!$_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
}
$build = !$exists -or $Force.IsPresent
"sha=$sha", "tag=$tag", "build=$($build.ToString().ToLowerInvariant())", "exists=$($exists.ToString().ToLowerInvariant())" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
@{ upstream_sha = $sha; recipe_hash = $recipe; release_tag = $tag; already_published = $exists; build = $build } | ConvertTo-Json | Write-Output
if (!$build) { 'Upstream and build recipe are unchanged; retaining the published release.' | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
