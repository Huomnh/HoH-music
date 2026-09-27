param(
  [switch]$SkipBuild,
  [switch]$SkipInstallerSmokeTest
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

$releaseDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$releaseExe = Join-Path $releaseDir 'hoh_music.exe'
$stagingDir = Join-Path $projectRoot 'build\packaging'
$installerDir = Join-Path $projectRoot 'dist\windows'
$redistPath = Join-Path $stagingDir 'vc_redist.x64.exe'
$installerCompiler = @(
  'C:\Program Files\Inno Setup 6\ISCC.exe',
  'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
$installerScript = Join-Path $projectRoot 'packaging\hoh_music.iss'
# Build the Unicode folder name from code points so Windows PowerShell 5 can
# read this UTF-8-without-BOM script without corrupting the path.
$manualSourcesDir = Join-Path $projectRoot ('music' + [char]0x97F3 + [char]0x6E90)

if (-not $SkipBuild) {
  & flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "Flutter Release build failed with exit code $LASTEXITCODE" }
}

$requiredPaths = @(
  $releaseExe,
  (Join-Path $releaseDir 'data\flutter_assets\NOTICES.Z'),
  (Join-Path $releaseDir 'libmpv-2.dll'),
  (Join-Path $releaseDir 'media_kit_libs_windows_video_plugin.dll'),
  (Join-Path $releaseDir 'quickjs_c_bridge.dll'),
  (Join-Path $projectRoot 'LICENSE'),
  (Join-Path $manualSourcesDir 'README.md'),
  $installerScript
)
foreach ($requiredPath in $requiredPaths) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required packaging input is missing: $requiredPath"
  }
}
$manualSourceFiles = @(Get-ChildItem -LiteralPath $manualSourcesDir -Filter '*.js' -File)
if ($manualSourceFiles.Count -eq 0) {
  throw "No manually importable source scripts found in $manualSourcesDir"
}
if (-not (Test-Path -LiteralPath (Join-Path $releaseDir 'data\flutter_assets') -PathType Container)) {
  throw 'Flutter asset bundle is missing from the Windows Release output.'
}

# Flutter asset bundles may retain stale files after an asset declaration is removed.
# These generated bundle folders are deliberately excluded; repository source files remain untouched.
$excludedAssetDirs = @(
  (Join-Path $releaseDir 'data\flutter_assets\assets\audio'),
  (Join-Path $releaseDir 'data\flutter_assets\assets\sources')
)
foreach ($excludedAssetDir in $excludedAssetDirs) {
  if (Test-Path -LiteralPath $excludedAssetDir -PathType Container) {
    Remove-Item -LiteralPath $excludedAssetDir -Recurse -Force
  }
}
foreach ($excludedAssetDir in $excludedAssetDirs) {
  if (Test-Path -LiteralPath $excludedAssetDir) {
    throw "Personal audio/source assets must not be present in the packaged Flutter bundle: $excludedAssetDir"
  }
}

if (-not $installerCompiler) {
  throw 'Inno Setup 6 compiler not found. Install Inno Setup 6 and retry.'
}

New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
New-Item -ItemType Directory -Path $installerDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $redistPath -PathType Leaf)) {
  Write-Host 'Downloading the official Microsoft x64 Visual C++ Redistributable...'
  Invoke-WebRequest -Uri 'https://aka.ms/vc14/vc_redist.x64.exe' -OutFile $redistPath
}
$signature = Get-AuthenticodeSignature -FilePath $redistPath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
  throw "The Visual C++ Redistributable signature is not valid or not from Microsoft: $($signature.Status)"
}

& $installerCompiler $installerScript
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE" }

$installer = Get-ChildItem -LiteralPath $installerDir -Filter 'HoH-music-Setup-*-Windows-x64.exe' -File |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if ($null -eq $installer) { throw "Installer output was not created in $installerDir" }

if (-not $SkipInstallerSmokeTest) {
  $smokeDir = Join-Path $stagingDir 'smoke-install'
  if (Test-Path -LiteralPath $smokeDir) {
    throw "Smoke-test target already exists; refusing to overwrite it: $smokeDir"
  }
  $installArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR="{0}"' -f $smokeDir
  $installProcess = Start-Process -FilePath $installer.FullName -ArgumentList $installArgs -Wait -PassThru
  if ($installProcess.ExitCode -ne 0) { throw "Silent installer smoke test failed: $($installProcess.ExitCode)" }
  if (-not (Test-Path -LiteralPath (Join-Path $smokeDir 'hoh_music.exe') -PathType Leaf)) {
    throw 'Smoke test did not install the application executable to the chosen custom directory.'
  }
  $requiredInstalledFiles = @(
    'LICENSE',
    'licenses\THIRD-PARTY-LICENSES.md',
    'libmpv-2.dll',
    'quickjs_c_bridge.dll',
    'media_kit_libs_windows_video_plugin.dll',
    'data\flutter_assets\NOTICES.Z'
  )
  foreach ($relativePath in $requiredInstalledFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $smokeDir $relativePath) -PathType Leaf)) {
      throw "Smoke test installation is missing a runtime/license file: $relativePath"
    }
  }
  $installedSourceDir = Join-Path $smokeDir ('music' + [char]0x97F3 + [char]0x6E90)
  foreach ($sourceFile in $manualSourceFiles) {
    $installedSourcePath = Join-Path $installedSourceDir $sourceFile.Name
    if (-not (Test-Path -LiteralPath $installedSourcePath -PathType Leaf)) {
      throw "Manually importable source was not installed: $($sourceFile.Name)"
    }
    if ((Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $installedSourcePath -Algorithm SHA256).Hash) {
      throw "Installed source content differs from the project file: $($sourceFile.Name)"
    }
  }
  $installedAssetRoot = Join-Path $smokeDir 'data\flutter_assets\assets'
  foreach ($excludedName in @('audio', 'sources')) {
    if (Test-Path -LiteralPath (Join-Path $installedAssetRoot $excludedName)) {
      throw "Unexpected bundled asset folder was installed: $excludedName"
    }
  }
  $uninstaller = Join-Path $smokeDir 'unins000.exe'
  if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Smoke test did not create the uninstaller.' }
  $uninstallArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
  $uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList $uninstallArgs -Wait -PassThru
  if ($uninstallProcess.ExitCode -ne 0) { throw "Silent uninstall smoke test failed: $($uninstallProcess.ExitCode)" }
  if (Test-Path -LiteralPath $smokeDir) { Remove-Item -LiteralPath $smokeDir -Recurse -Force }
}

$hash = Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256
Write-Host "Installer: $($installer.FullName)"
Write-Host "Size: $([math]::Round($installer.Length / 1MB, 2)) MiB"
Write-Host "SHA-256: $($hash.Hash)"
