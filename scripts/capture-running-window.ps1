# capture-running-window.ps1
#
# Capture an ALREADY RUNNING "HoH music" window (does not launch the app).
#
# Why this exists: scripts/capture-window.ps1 starts the app itself, so it cannot
# be used when the window has state we care about (a track playing at a specific
# position, a specific page open, ...). This one only captures.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\capture-running-window.ps1 -Out build\shot.png
#
# NOTE: this file is intentionally ASCII-only. PowerShell 5.1 parses .ps1 files
# as GBK unless they carry a UTF-8 BOM, so non-ASCII comments here would break
# the script (see docs/项目进度交接.md, the .ps1 pitfall).

[CmdletBinding()]
param(
    [string] $ProjectRoot = '',
    [string] $Out = 'build\running-window.png',
    [int] $Width = 1400,
    [int] $Height = 880,
    [int] $X = 60,
    [int] $Y = 40,
    [switch] $KeepTopmost
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
if (-not ('RunningWinCap' -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public struct RWC_RECT { public int Left, Top, Right, Bottom; }

public class RunningWinCap {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RWC_RECT r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int cx, int cy, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);

  public static IntPtr FindByTitle(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(512);
      GetWindowText(h, sb, sb.Capacity);
      if (sb.ToString() == title) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
}

$target = [RunningWinCap]::FindByTitle('HoH music')
if ($target -eq [IntPtr]::Zero) {
    throw "No visible window titled 'HoH music' - start the app first"
}

Write-Host ("Locked window hwnd={0}" -f $target) -ForegroundColor Green
[void][RunningWinCap]::MoveWindow($target, $X, $Y, $Width, $Height, $true)
# HWND_TOPMOST (-1) so the capture is not covered by other windows
[void][RunningWinCap]::SetWindowPos($target, [IntPtr]::new(-1), 0, 0, 0, 0, 3)
Start-Sleep -Seconds 2

$r = New-Object RWC_RECT
[void][RunningWinCap]::GetWindowRect($target, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
Write-Host "  window rect ($($r.Left),$($r.Top)) ${w}x${h}"

$dir = Split-Path -Parent $outPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()

if (-not $KeepTopmost) {
    [void][RunningWinCap]::SetWindowPos($target, [IntPtr]::new(-2), 0, 0, 0, 0, 3)
}

Write-Host ("Saved: {0}" -f $outPath.Replace($ProjectRoot + '\', '')) -ForegroundColor Green
