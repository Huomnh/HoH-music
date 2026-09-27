# prepare-media-kit.ps1
#
# 作用：为 media_kit_libs_windows_video 预下载 libmpv 与 ANGLE 压缩包。
#
# 为什么需要这个脚本？
#   media_kit 的 CMake 脚本会在构建时从 GitHub Releases 下载这两个压缩包。
#   本机网络无法直连 GitHub（release-assets.githubusercontent.com 不可达），
#   下载会失败并报：
#       Integrity check failed, please try to rebuild project again.
#   CMake 的逻辑是「文件存在且 MD5 匹配就跳过下载」，所以只要提前把文件
#   放到它期望的位置并保证 MD5 正确，构建就能顺利进行。
#
# 使用时机：
#   - 首次构建前
#   - 执行过 flutter clean 或删除了 build\ 目录之后
#
# 用法：
#   cd E:\HoH-music
#   powershell -ExecutionPolicy Bypass -File scripts\prepare-media-kit.ps1

[CmdletBinding()]
param(
    # 项目根目录。留空则自动推断。
    # 注意：PowerShell 5.1 不允许在 param 默认值里引用 $PSScriptRoot，
    # 所以这里先留空，进入脚本体后再解析。
    [string] $ProjectRoot = '',

    # GitHub 加速镜像前缀。若失效可在注释里换用备用镜像：
    #   https://gh-proxy.com/  https://ghfast.top/  https://hub.gitmirror.com/
    [string] $Mirror = 'https://ghproxy.net/',

    # 直连失败时是否回退到镜像
    [switch] $Direct
)

$ErrorActionPreference = 'Stop'

# 解析项目根目录：优先用参数，否则取本脚本所在目录的上一级
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ProjectRoot = (Get-Location).Path
    } else {
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
    }
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

# 校验确实在项目根目录，避免放错位置时把文件下到无关目录
if (-not (Test-Path (Join-Path $ProjectRoot 'pubspec.yaml'))) {
    Write-Host "[X] 在 $ProjectRoot 下找不到 pubspec.yaml" -ForegroundColor Red
    Write-Host '    请在项目根目录执行，或显式指定路径：' -ForegroundColor Yellow
    Write-Host '    powershell -ExecutionPolicy Bypass -File scripts\prepare-media-kit.ps1 -ProjectRoot E:\HoH-music' -ForegroundColor DarkGray
    exit 1
}

$destDir = Join-Path $ProjectRoot 'build\windows\x64'

$items = @(
    @{
        Name = 'mpv-dev-x86_64-20230924-git-652a1dd.7z'
        Url  = 'https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z'
        Md5  = 'a832ef24b3a6ff97cd2560b5b9d04cd8'
    },
    @{
        Name = 'ANGLE.7z'
        Url  = 'https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z'
        Md5  = 'e866f13e8d552348058afaafe869b1ed'
    }
)

Write-Host ''
Write-Host '为 media_kit 准备原生库压缩包' -ForegroundColor Cyan
Write-Host "  目标目录 : $destDir"
Write-Host "  镜像前缀 : $Mirror"
Write-Host ''

if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Write-Host "  已创建目录 $destDir" -ForegroundColor DarkGray
}

function Get-Md5([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLower()
}

$failed = @()

foreach ($item in $items) {
    $out = Join-Path $destDir $item.Name
    Write-Host "▶ $($item.Name)" -ForegroundColor White

    # 已存在且校验通过则跳过
    if (Test-Path $out) {
        $existing = Get-Md5 $out
        if ($existing -eq $item.Md5) {
            Write-Host '  已存在且 MD5 校验通过，跳过' -ForegroundColor Green
            continue
        }
        Write-Host "  已存在但 MD5 不匹配（$existing），将重新下载" -ForegroundColor Yellow
        Remove-Item $out -Force
    }

    $urls = @()
    if ($Direct) { $urls += $item.Url }
    $urls += ($Mirror + $item.Url)

    $ok = $false
    foreach ($url in $urls) {
        $host_ = ([Uri]$url).Host
        Write-Host "  正在从 $host_ 下载 ..." -ForegroundColor DarkGray
        try {
            & curl.exe -sS -o $out --max-time 300 --retry 2 -L $url 2>$null
            if ($LASTEXITCODE -ne 0) { throw "curl 退出码 $LASTEXITCODE" }
        } catch {
            Write-Host "    下载失败：$($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }

        if (-not (Test-Path $out)) { continue }

        $size = (Get-Item $out).Length
        if ($size -eq 0) {
            Write-Host '    下载结果为空文件' -ForegroundColor Yellow
            Remove-Item $out -Force -ErrorAction SilentlyContinue
            continue
        }

        $actual = Get-Md5 $out
        if ($actual -eq $item.Md5) {
            Write-Host ("  完成：{0:N1} MB，MD5 校验通过 ✅" -f ($size / 1MB)) -ForegroundColor Green
            $ok = $true
            break
        }

        Write-Host "    MD5 不匹配：期望 $($item.Md5)，实际 $actual" -ForegroundColor Yellow
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }

    if (-not $ok) { $failed += $item.Name }
}

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host '全部就绪，可以执行构建了：' -ForegroundColor Green
    Write-Host '  flutter pub get' -ForegroundColor DarkGray
    Write-Host '  flutter build windows --debug' -ForegroundColor DarkGray
    exit 0
}

Write-Host "以下文件准备失败：$($failed -join ', ')" -ForegroundColor Red
Write-Host '排查建议：' -ForegroundColor Yellow
Write-Host '  1. 换一个镜像前缀后重试：' -ForegroundColor Yellow
Write-Host '     .\scripts\prepare-media-kit.ps1 -Mirror "https://gh-proxy.com/"' -ForegroundColor DarkGray
Write-Host '  2. 开启你的代理软件后重试（本机代理端口为 127.0.0.1:7897）' -ForegroundColor Yellow
Write-Host '  3. 手动下载后放入 build\windows\x64\，文件名必须完全一致' -ForegroundColor Yellow
exit 1
