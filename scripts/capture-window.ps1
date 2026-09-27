# capture-window.ps1
#
# 可靠地截取 HoH music 窗口，并采样四角像素判断圆角是否生效。
#
# 为什么单独写一个：preview.ps1 里用 Get-Process 的 MainWindowHandle 定位窗口，
# 在有多个同名进程 / 窗口未及时刷新时会抓到别的窗口。这里改成
# EnumWindows + 标题 + 进程名三重校验，并在截图后**自动采样角落像素**，
# 避免"截图截错窗口却以为圆角没生效"。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\capture-window.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\capture-window.ps1 -Out docs\preview\x.png

[CmdletBinding()]
param(
    [string] $ProjectRoot = '',
    [string] $Out = 'docs\preview\player-rounded.png',
    [int] $Width = 1400,
    [int] $Height = 880,
    [int] $X = 60,
    [int] $Y = 40,
    # 应用启动后多少秒自动优雅退出。脚本自己大约用 16 秒（启动 9s + 摆窗口 6s），
    # 留点余量即可；窗口出现慢的机器可以调大。
    [int] $ExitAfter = 22,
    [switch] $KeepRunning
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        (Get-Location).Path
    } else {
        Split-Path -Parent $PSScriptRoot
    }
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$outPath = Join-Path $ProjectRoot $Out

Add-Type -AssemblyName System.Drawing
if (-not ('WinCap' -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public struct WC_RECT { public int Left, Top, Right, Bottom; }

public class WinCap {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out WC_RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int cx, int cy, bool repaint);

  /// 按进程名找出该进程下所有可见且有标题的顶层窗口
  public static List<IntPtr> FindWindows(int pid) {
    var found = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      uint wpid;
      GetWindowThreadProcessId(h, out wpid);
      if (wpid != (uint)pid) return true;
      if (!IsWindowVisible(h)) return true;
      if (GetWindowTextLength(h) == 0) return true;
      found.Add(h);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string TitleOf(IntPtr h) {
    var sb = new StringBuilder(512);
    GetWindowText(h, sb, sb.Capacity);
    return sb.ToString();
  }
}
"@
}

$exe = Join-Path $ProjectRoot 'build\windows\x64\runner\Debug\hoh_music.exe'

# ── 确保只有一个实例 ─────────────────────────────────────────────
# ⚠️ 这里强杀上一个实例是无奈的兜底（它可能已经在托盘里挂着）。
# 正常收尾走下面的 -ExitAfter，强杀会在任务栏留下"幽灵图标"。
Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 600

if (-not (Test-Path $exe)) { throw "找不到可执行文件：$exe（先构建）" }

Write-Host '▶ 启动应用 ...' -ForegroundColor Cyan
# `--exit-after` 让应用到点自己走托盘菜单那条退出流程：
# 会先 Shell_NotifyIcon(NIM_DELETE) 撤掉托盘图标，再销毁窗口。
# 直接用 Stop-Process 强杀的话，图标会留在任务栏（用户 0.0.21 报过一堆重复图标）。
# stderr 落到 build\capture-window-app.log：启动 / 托盘 / 退出这些日志都在里面。
$appLog = Join-Path $ProjectRoot 'build\capture-window-app.log'
$appLogDir = Split-Path -Parent $appLog
if (-not (Test-Path $appLogDir)) {
    New-Item -ItemType Directory -Path $appLogDir -Force | Out-Null
}
Remove-Item -LiteralPath $appLog -ErrorAction SilentlyContinue
Start-Process -FilePath $exe -ArgumentList "--exit-after=$ExitAfter" `
    -RedirectStandardError $appLog | Out-Null

# ── 定位窗口 ─────────────────────────────────────────────────────
# 轮询等窗口出现（最多 30 秒）。原来固定睡 9 秒再查一次，
# 冷启动慢的时候会误报"进程未启动"（0.0.22 真遇到过一次，重跑就好）。
$waitDeadline = (Get-Date).AddSeconds(30)
$target = [IntPtr]::Zero
while ((Get-Date) -lt $waitDeadline) {
    $procs = Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        foreach ($h in [WinCap]::FindWindows($p.Id)) {
            # 只认应用的精确标题，避免误匹配浏览器标签或其他窗口。
            # 可能正好有本项目的对话页面，会被误匹配成应用窗口。
            if ([WinCap]::TitleOf($h) -eq 'HoH music') { $target = $h; break }
        }
        if ($target -ne [IntPtr]::Zero) { break }
    }
    if ($target -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 500
}
if ($target -eq [IntPtr]::Zero) {
    throw "等了 30 秒也没找到标题为 'HoH music' 的可见窗口（看 build\capture-window-app.log）"
}
Write-Host ("✓ 锁定窗口 hwnd={0}" -f $target) -ForegroundColor Green

# ── 调整位置尺寸并置顶 ───────────────────────────────────────────
[void][WinCap]::MoveWindow($target, $X, $Y, $Width, $Height, $true)
Start-Sleep -Seconds 3
[void][WinCap]::ShowWindow($target, 9)
[void][WinCap]::SetWindowPos($target, [IntPtr]::new(-1), 0, 0, 0, 0, 3)
[void][WinCap]::SetForegroundWindow($target)
Start-Sleep -Seconds 3

$r = New-Object WC_RECT
[void][WinCap]::GetWindowRect($target, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
Write-Host "  窗口矩形 ($($r.Left),$($r.Top)) ${w}x${h}"

# ── 截图 ─────────────────────────────────────────────────────────
$dir = Split-Path -Parent $outPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# ⚠️ 优先用 PrintWindow 取**窗口自己**的像素：
# 用户正开着浏览器 / 别的应用时，窗口抢不到前台，CopyFromScreen 会截到
# 压在它上面的那个窗口（0.0.22 真踩过：截出来一整张浏览器）。
# PrintWindow(flags=2 / PW_RENDERFULLCONTENT) 对硬件加速窗口也管用。
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$mode = 'PrintWindow'
$ok = $false
try {
    $hdc = $g.GetHdc()
    try { $ok = [WinCap]::PrintWindow($target, $hdc, 2) } finally { $g.ReleaseHdc($hdc) }
} catch {
    $ok = $false
}

# 取到全黑说明没拿到内容（部分驱动会这样），退回屏幕拷贝
if ($ok) {
    $sample = 0; $lit = 0
    for ($x = 20; $x -lt $w; $x += 60) {
        for ($y = 20; $y -lt $h; $y += 60) {
            $sample++
            $px = $bmp.GetPixel($x, $y)
            if (($px.R + $px.G + $px.B) -gt 24) { $lit++ }
        }
    }
    if ($sample -eq 0 -or ($lit / $sample) -le 0.4) { $ok = $false }
}

if (-not $ok) {
    $mode = 'CopyFromScreen'
    # 这条路要求窗口真的在最前面，否则截到的是压着它的窗口 —— 先确认再截
    $fg = [WinCap]::GetForegroundWindow()
    if ($fg -ne $target) {
        [void][WinCap]::BringWindowToTop($target)
        [void][WinCap]::SetForegroundWindow($target)
        Start-Sleep -Milliseconds 800
        $fg = [WinCap]::GetForegroundWindow()
    }
    if ($fg -ne $target) {
        $g.Dispose(); $bmp.Dispose()
        throw ('截图失败：窗口抢不到前台（前台 hwnd={0}，目标 {1}）。' -f $fg, $target) +
              '你现在是不是正在用别的窗口？等几秒再跑一次，或直接用 PrintWindow 那条路。'
    }
    $g.Clear([System.Drawing.Color]::Black)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
}

$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host ("  截图方式：{0}" -f $mode) -ForegroundColor DarkGray

# ── 采样四角：圆角生效时角落应是桌面/异色，方角时是窗口内容 ──────
Write-Host ''
Write-Host '── 四角像素采样（离角落 3px 处）──────────────────' -ForegroundColor Cyan
$corners = @(
    @{ N = '左上'; X = 3;         Y = 3 },
    @{ N = '右上'; X = $w - 4;    Y = 3 },
    @{ N = '左下'; X = 3;         Y = $h - 4 },
    @{ N = '右下'; X = $w - 4;    Y = $h - 4 },
    @{ N = '内侧'; X = 20;        Y = 20 }
)
foreach ($c in $corners) {
    $px = $bmp.GetPixel($c.X, $c.Y)
    Write-Host ("  {0,-4} ({1,4},{2,4})  RGB({3,3},{4,3},{5,3})" -f `
        $c.N, $c.X, $c.Y, $px.R, $px.G, $px.B)
}
$g.Dispose()
$bmp.Dispose()

Write-Host ''
Write-Host ("✓ 截图已保存：{0}" -f $outPath.Replace($ProjectRoot + '\', '')) -ForegroundColor Green

[void][WinCap]::SetWindowPos($target, [IntPtr]::new(-2), 0, 0, 0, 0, 3)

if (-not $KeepRunning) {
    # 等应用自己优雅退出（--exit-after 到点会撤托盘图标再销毁窗口）。
    # 实在没退再强杀 —— 强杀可能残留一个幽灵图标，所以只当兜底。
    $deadline = (Get-Date).AddSeconds($ExitAfter + 8)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue)) {
            break
        }
        Start-Sleep -Milliseconds 400
    }
    if (Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue) {
        Write-Host '  ⚠ 应用没有自己退出，强杀（任务栏可能残留一个幽灵图标）' -ForegroundColor Yellow
        Get-Process -Name 'hoh_music' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host '  应用已优雅退出（托盘图标已撤，任务栏不留残留）' -ForegroundColor DarkGray
    }
}
