# preview.ps1
#
# 构建 → 启动 → 调整窗口尺寸 → 截图 → 关闭。
# 用于在 Windows 桌面上快速产出界面预览图。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\preview.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\preview.ps1 -Width 1280 -Height 800 -Name player
#
# 说明：脚本需要能访问窗口，请勿在无桌面会话（如纯 SSH）下运行。

[CmdletBinding()]
param(
    # 项目根目录，留空自动推断
    [string] $ProjectRoot = '',

    # 截图输出目录（相对项目根）
    [string] $OutDir = 'docs\preview',

    # 截图文件名（不含扩展名）
    [string] $Name = 'player-page',

    # 窗口尺寸
    [int] $Width = 1440,
    [int] $Height = 900,

    # 窗口左上角坐标
    [int] $X = 40,
    [int] $Y = 20,

    # 跳过构建（直接用现有产物）
    [switch] $SkipBuild,

    # 截图后保留应用运行
    [switch] $KeepRunning
)

$ErrorActionPreference = 'Stop'

# ── 解析项目根目录 ───────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ProjectRoot = (Get-Location).Path
    } else {
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
    }
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

$exe = Join-Path $ProjectRoot 'build\windows\x64\runner\Debug\hoh_music.exe'
$outPath = Join-Path (Join-Path $ProjectRoot $OutDir) "$Name.png"

# ── 窗口操作所需的 Win32 接口 ────────────────────────────────────
if (-not ('PreviewWin32' -as [type])) {
    Add-Type -AssemblyName System.Drawing
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct PREVIEW_RECT { public int Left, Top, Right, Bottom; }
public class PreviewWin32 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out PREVIEW_RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int cx, int cy, bool repaint);
}
"@
}

# 常量：TOPMOST / NOTOPMOST / NOSIZE / NOMOVE、SW_RESTORE
$HWND_TOPMOST   = [IntPtr]::new(-1)
$HWND_NOTOPMOST = [IntPtr]::new(-2)
$SWP_NOSIZE_NOMOVE = 0x0001 -bor 0x0002
$SW_RESTORE = 9

# ── 关闭已在运行的实例 ───────────────────────────────────────────
Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ── 构建 ─────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Host '▶ 构建 Windows 调试版 ...' -ForegroundColor Cyan
    Push-Location $ProjectRoot
    try {
        $env:Path = 'E:\flutter-sdk\flutter\bin;' + $env:Path
        & flutter build windows --debug 2>&1 |
            Select-String -Pattern '√ Built|error|Build process failed' |
            ForEach-Object { '  ' + $_.Line.Trim() }
        if ($LASTEXITCODE -ne 0) { throw "构建失败（退出码 $LASTEXITCODE）" }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $exe)) { throw "找不到可执行文件：$exe" }

# ── 启动并等待首帧 ───────────────────────────────────────────────
Write-Host '▶ 启动应用 ...' -ForegroundColor Cyan
Start-Process -FilePath $exe | Out-Null
Start-Sleep -Seconds 10

$proc = Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw '未找到应用窗口，可能启动失败' }
$hwnd = $proc.MainWindowHandle

# ── 调整窗口并置顶激活 ───────────────────────────────────────────
[void][PreviewWin32]::MoveWindow($hwnd, $X, $Y, $Width, $Height, $true)
Start-Sleep -Seconds 3
[void][PreviewWin32]::ShowWindow($hwnd, $SW_RESTORE)
[void][PreviewWin32]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_NOSIZE_NOMOVE)
[void][PreviewWin32]::SetForegroundWindow($hwnd)
Start-Sleep -Seconds 3

# ── 截图 ─────────────────────────────────────────────────────────
$rect = New-Object PREVIEW_RECT
[void][PreviewWin32]::GetWindowRect($hwnd, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top

$dir = Split-Path -Parent $outPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()

# 取消置顶
[void][PreviewWin32]::SetWindowPos($hwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP_NOSIZE_NOMOVE)

Write-Host ("✓ 截图已保存：{0}  ({1}x{2}, {3:N0} KB)" -f `
    $outPath.Replace($ProjectRoot + '\', ''), $w, $h, ((Get-Item $outPath).Length / 1KB)) `
    -ForegroundColor Green

if (-not $KeepRunning) {
    Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 2
    Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '  应用已关闭' -ForegroundColor DarkGray
}
