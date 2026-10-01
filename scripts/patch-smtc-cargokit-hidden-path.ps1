$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$resolverPath = Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks\smtc_windows\cargokit\cmake\resolve_symlinks.ps1'

if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) {
  Write-Host 'Flutter generated plugin links are missing; running flutter pub get first.'
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed with exit code $LASTEXITCODE" }
}

if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) {
  throw 'smtc_windows Cargokit resolver not found after flutter pub get.'
}

$source = [System.IO.File]::ReadAllText($resolverPath)
$buggyLine = '$item = Get-Item $realPath'
$fixedLine = '$item = Get-Item -Force $realPath'

if ($source.Contains($fixedLine)) {
  Write-Host 'smtc_windows Cargokit hidden-path compatibility fix is already applied.'
  exit 0
}

if (-not $source.Contains($buggyLine)) {
  throw 'Unexpected smtc_windows resolver contents; refusing to modify an unknown version.'
}

$patched = $source.Replace($buggyLine, $fixedLine)
[System.IO.File]::WriteAllText($resolverPath, $patched, [System.Text.UTF8Encoding]::new($false))
Write-Host 'Patched smtc_windows Cargokit resolver to traverse hidden Windows profile directories.'
