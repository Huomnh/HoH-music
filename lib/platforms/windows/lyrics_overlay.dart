/// lyrics_overlay.dart
///
/// **桌面歌词浮层**（Windows）—— 独立的置顶小窗，把歌词浮在桌面上。
///
/// 为什么不用现成插件：`desktop_lyrics` 对 Win10 支持存疑、样式几乎不可控；
/// `desktop_multi_window` 要再起一个 Flutter 引擎、还得自己做 IPC，而且子窗口
/// 做不出**逐像素透明**。所以这里直接调 Win32：**分层窗口（WS_EX_LAYERED）+
/// `UpdateLayeredWindow`**，自己用 GDI 画字 —— 不引第三方依赖，透明度/穿透/置顶可控。
///
/// 窗口特性：
/// - `WS_EX_LAYERED` + `UpdateLayeredWindow(ULW_ALPHA)`：逐像素透明；
/// - `WS_EX_TRANSPARENT`：鼠标事件穿透，不挡住下面的窗口；
/// - `WS_EX_TOPMOST` + `WS_EX_NOACTIVATE` + `WS_EX_TOOLWINDOW`：永远最上层、
///   点它不抢焦点、不进 Alt-Tab 与任务栏。
///
/// ## 画面结构（0.0.26 重做）
///
/// ```
/// ┌──────────────────────────────────────────┐  ← 白色半透明玻璃胶囊（可关）
/// │  当前这句（大）                            │  ← 深色液态玻璃与主题色流动高光
/// │  翻译 / 下一句（小、更淡）                  │
/// └──────────────────────────────────────────┘
/// ```
///
/// - **两行**：第一行=当前句；第二行=**该句的翻译**，没有翻译时显示**下一句**。
/// - **换行动效**：换句时旧句上移淡出、新句从第二行的位置升上来淡入（约 320ms）。
/// - **玻璃框可关**（`LyricsStyle.overlayFrame`）：关掉后只剩文字，
///   文字自动切成"白色 + 深色描边"，保证在任意桌面背景上都看得清。
/// - **边框高光流动**：只在玻璃框显示时跑（30Hz 定时器重绘**只有边框那一圈**）。
///
/// ## 两个只有真跑才会撞到的坑
///
/// 1. **GDI 不写 alpha 通道**：往 32bpp DIB 画字，A 字节永远是 0，而
///    `UpdateLayeredWindow(ULW_ALPHA)` 只看 alpha ⇒ 直接推上去是**全透明**。
///    所以用"白字当覆盖率"：每个图层画到自己的 32bpp DIB 里（白色=覆盖率），
///    再**在 Dart 里合成 premultiplied BGRA**。
/// 2. **字体句柄不能跟着画布一起释放**：0.0.25 的版本在重建画布时把字体也删了，
///    结果 `SelectObject(dc, 0)` → GDI 退回**系统默认小字体** ——
///    用户看到的就是"字体和大小会变"。现在字体独立管理，画布重建后重新 select。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, HSVColor;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_providers.dart';
import '../../features/player/lyrics/lyrics_style.dart';
import '../../features/player/lyrics/lyrics_view.dart';
import '../../features/player/lyrics/lyrics_parser.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/performance_tier.dart';

void _log(String message) => stderr.writeln('[LyricsOverlay] $message');

const int _wmNcHitTest = 0x0084;
const int _wmExitSizeMove = 0x0232;
const int _htCaption = 2;
const int _htTransparent = -1;
int _lyricsWindowProc(int hwnd, int message, int wParam, int lParam) {
  if (message == _wmNcHitTest) {
    return LyricsOverlay.instance._hitTest(lParam);
  }
  if (message == _wmExitSizeMove) {
    LyricsOverlay.instance._syncDraggedPosition();
  }
  return _DefWindowProc(hwnd, message, wParam, lParam);
}

// ── Win32 常量 ────────────────────────────────────────────────────

const int _wsPopup = 0x80000000;
const int _wsExLayered = 0x00080000;
const int _wsExTopmost = 0x00000008;
const int _wsExToolWindow = 0x00000080;
const int _wsExNoActivate = 0x08000000;

const int _swShowNoActivate = 4;
const int _swHide = 0;

const int _hwndTopmost = -1;
const int _swpNoActivate = 0x0010;
const int _swpShowWindow = 0x0040;
const int _gwlpWndProc = -4;

const int _ulwAlpha = 0x00000002;
const int _acSrcOver = 0;
const int _acSrcAlpha = 1;

const int _dibRgbColors = 0;
const int _biRgb = 0;

const int _transparent = 1;
const int _dtCenter = 0x00000001;
const int _dtVCenter = 0x00000004;
const int _dtSingleLine = 0x00000020;
const int _dtNoPrefix = 0x00000800;
const int _dtEndEllipsis = 0x00004000;
const int _dtLeft = 0x00000000;

const int _defaultCharset = 1;
const int _outTtPrecis = 4;
const int _cleartypeQuality = 5;
const int _fwSemibold = 600;
const int _fwNormal = 400;

const int _smCxScreen = 0;
const int _smCyScreen = 1;

// 画笔常量
const int _psSolid = 0;
const int _psEndcapRound = 2; // PS_ENDCAP_ROUND
const int _psJoinRound = 2; // PS_JOIN_ROUND

/// 换行动效时长。
const Duration _transition = Duration(milliseconds: 300);

/// 播放器式换句动画节拍；玻璃框本身保持静止，避免边框重绘抖动。
const Duration _animationTick = Duration(milliseconds: 50);

// ── 结构体 ────────────────────────────────────────────────────────

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _Size extends Struct {
  @Int32()
  external int cx;
  @Int32()
  external int cy;
}

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _BlendFunction extends Struct {
  @Uint8()
  external int blendOp;
  @Uint8()
  external int blendFlags;
  @Uint8()
  external int sourceConstantAlpha;
  @Uint8()
  external int alphaFormat;
}

/// `BITMAPINFOHEADER`（32bpp BI_RGB 不需要调色板，只用到这 40 字节）。
final class _BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight;
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression;
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

// ── Win32 绑定 ────────────────────────────────────────────────────

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _gdi32 = DynamicLibrary.open('gdi32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

typedef _CreateWindowExWNative = IntPtr Function(
  Uint32,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Uint32,
  Int32,
  Int32,
  Int32,
  Int32,
  IntPtr,
  IntPtr,
  IntPtr,
  Pointer<Void>,
);
typedef _CreateWindowExWDart = int Function(
  int,
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  Pointer<Void>,
);

typedef _BoolHwndNative = Int32 Function(IntPtr);
typedef _BoolHwndDart = int Function(int);
typedef _WndProcNative = IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _WndProcDart = int Function(int, int, int, int);
typedef _SetWindowLongPtrNative = IntPtr Function(
  IntPtr,
  Int32,
  Pointer<NativeFunction<_WndProcNative>>,
);
typedef _SetWindowLongPtrDart = int Function(
  int,
  int,
  Pointer<NativeFunction<_WndProcNative>>,
);
typedef _DefWindowProcNative = IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _DefWindowProcDart = int Function(int, int, int, int);

typedef _ShowWindowNative = Int32 Function(IntPtr, Int32);
typedef _ShowWindowDart = int Function(int, int);

typedef _SetWindowPosNative = Int32 Function(
  IntPtr,
  IntPtr,
  Int32,
  Int32,
  Int32,
  Int32,
  Uint32,
);
typedef _SetWindowPosDart = int Function(int, int, int, int, int, int, int);

typedef _GetSystemMetricsNative = Int32 Function(Int32);
typedef _GetSystemMetricsDart = int Function(int);
typedef _GetWindowRectNative = Int32 Function(IntPtr, Pointer<_Rect>);
typedef _GetWindowRectDart = int Function(int, Pointer<_Rect>);
typedef _GetCursorPosNative = Int32 Function(Pointer<_Point>);
typedef _GetCursorPosDart = int Function(Pointer<_Point>);
typedef _SystemParametersInfoNative = Int32 Function(
  Uint32,
  Uint32,
  Pointer<_Rect>,
  Uint32,
);
typedef _SystemParametersInfoDart = int Function(int, int, Pointer<_Rect>, int);

typedef _GetDcNative = IntPtr Function(IntPtr);
typedef _GetDcDart = int Function(int);

typedef _ReleaseDcNative = Int32 Function(IntPtr, IntPtr);
typedef _ReleaseDcDart = int Function(int, int);

typedef _GetModuleHandleNative = IntPtr Function(Pointer<Utf16>);
typedef _GetModuleHandleDart = int Function(Pointer<Utf16>);

typedef _UpdateLayeredWindowNative = Int32 Function(
  IntPtr,
  IntPtr,
  Pointer<_Point>,
  Pointer<_Size>,
  IntPtr,
  Pointer<_Point>,
  Uint32,
  Pointer<_BlendFunction>,
  Uint32,
);
typedef _UpdateLayeredWindowDart = int Function(
  int,
  int,
  Pointer<_Point>,
  Pointer<_Size>,
  int,
  Pointer<_Point>,
  int,
  Pointer<_BlendFunction>,
  int,
);

typedef _CreateCompatibleDcNative = IntPtr Function(IntPtr);
typedef _CreateCompatibleDcDart = int Function(int);

typedef _DeleteDcNative = Int32 Function(IntPtr);
typedef _DeleteDcDart = int Function(int);

typedef _CreateDibSectionNative = IntPtr Function(
  IntPtr,
  Pointer<_BitmapInfoHeader>,
  Uint32,
  Pointer<Pointer<Void>>,
  IntPtr,
  Uint32,
);
typedef _CreateDibSectionDart = int Function(
  int,
  Pointer<_BitmapInfoHeader>,
  int,
  Pointer<Pointer<Void>>,
  int,
  int,
);

typedef _SelectObjectNative = IntPtr Function(IntPtr, IntPtr);
typedef _SelectObjectDart = int Function(int, int);

typedef _DeleteObjectNative = Int32 Function(IntPtr);
typedef _DeleteObjectDart = int Function(int);

typedef _CreateFontNative = IntPtr Function(
  Int32,
  Int32,
  Int32,
  Int32,
  Int32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Utf16>,
);
typedef _CreateFontDart = int Function(
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  int,
  Pointer<Utf16>,
);

typedef _SetTextColorNative = Int32 Function(IntPtr, Uint32);
typedef _SetTextColorDart = int Function(int, int);

typedef _SetBkModeNative = Int32 Function(IntPtr, Int32);
typedef _SetBkModeDart = int Function(int, int);

typedef _DrawTextNative = Int32 Function(
  IntPtr,
  Pointer<Utf16>,
  Int32,
  Pointer<_Rect>,
  Uint32,
);
typedef _DrawTextDart = int Function(
  int,
  Pointer<Utf16>,
  int,
  Pointer<_Rect>,
  int,
);

typedef _GetTextExtentNative = Int32 Function(
  IntPtr,
  Pointer<Utf16>,
  Int32,
  Pointer<_Size>,
);
typedef _GetTextExtentDart = int Function(
  int,
  Pointer<Utf16>,
  int,
  Pointer<_Size>,
);

typedef _CreatePenNative = Int32 Function(Int32, Int32, Uint32);
typedef _CreatePenDart = int Function(int, int, int);

typedef _MoveToExNative = Int32 Function(IntPtr, Int32, Int32, Pointer<_Point>);
typedef _MoveToExDart = int Function(int, int, int, Pointer<_Point>);

typedef _LineToNative = Int32 Function(IntPtr, Int32, Int32);
typedef _LineToDart = int Function(int, int, int);

// ⚠️ 画字的是 user32 的 DrawTextW（不是 gdi32 的）：写错 dll 会在**运行期**
// 抛 "Failed to lookup symbol"，编译期一点都不报。
final _DrawTextW = _user32.lookupFunction<_DrawTextNative, _DrawTextDart>(
  'DrawTextW',
);

final _CreateWindowExW = _user32
    .lookupFunction<_CreateWindowExWNative, _CreateWindowExWDart>(
      'CreateWindowExW',
    );
final _DestroyWindow = _user32.lookupFunction<_BoolHwndNative, _BoolHwndDart>(
  'DestroyWindow',
);
final _SetWindowLongPtr = _user32
    .lookupFunction<_SetWindowLongPtrNative, _SetWindowLongPtrDart>(
      'SetWindowLongPtrW',
    );
final _DefWindowProc = _user32
    .lookupFunction<_DefWindowProcNative, _DefWindowProcDart>('DefWindowProcW');
final Pointer<NativeFunction<_WndProcNative>> _lyricsWindowProcPtr =
    Pointer.fromFunction<_WndProcNative>(_lyricsWindowProc, 0);
final _ShowWindow = _user32.lookupFunction<_ShowWindowNative, _ShowWindowDart>(
  'ShowWindow',
);
final _SetWindowPos = _user32
    .lookupFunction<_SetWindowPosNative, _SetWindowPosDart>('SetWindowPos');
final _GetSystemMetrics = _user32
    .lookupFunction<_GetSystemMetricsNative, _GetSystemMetricsDart>(
      'GetSystemMetrics',
    );
final _GetWindowRect = _user32
    .lookupFunction<_GetWindowRectNative, _GetWindowRectDart>('GetWindowRect');
final _GetCursorPos = _user32
    .lookupFunction<_GetCursorPosNative, _GetCursorPosDart>('GetCursorPos');
final _SystemParametersInfo = _user32
    .lookupFunction<_SystemParametersInfoNative, _SystemParametersInfoDart>(
      'SystemParametersInfoW',
    );

const int _spiGetWorkArea = 0x0030;

int _workAreaBottom() {
  final Pointer<_Rect> rect = calloc<_Rect>();
  try {
    if (_SystemParametersInfo(_spiGetWorkArea, 0, rect, 0) != 0) {
      return rect.ref.bottom;
    }
  } finally {
    calloc.free(rect);
  }
  return _GetSystemMetrics(_smCyScreen);
}

final _userGetDc = _user32.lookupFunction<_GetDcNative, _GetDcDart>('GetDC');
final _ReleaseDc = _user32.lookupFunction<_ReleaseDcNative, _ReleaseDcDart>(
  'ReleaseDC',
);
final _UpdateLayeredWindow = _user32
    .lookupFunction<_UpdateLayeredWindowNative, _UpdateLayeredWindowDart>(
      'UpdateLayeredWindow',
    );

final _GetModuleHandleW = _kernel32
    .lookupFunction<_GetModuleHandleNative, _GetModuleHandleDart>(
      'GetModuleHandleW',
    );

final _CreateCompatibleDc = _gdi32
    .lookupFunction<_CreateCompatibleDcNative, _CreateCompatibleDcDart>(
      'CreateCompatibleDC',
    );
final _DeleteDc = _gdi32.lookupFunction<_DeleteDcNative, _DeleteDcDart>(
  'DeleteDC',
);
final _CreateDibSection = _gdi32
    .lookupFunction<_CreateDibSectionNative, _CreateDibSectionDart>(
      'CreateDIBSection',
    );
final _SelectObject = _gdi32
    .lookupFunction<_SelectObjectNative, _SelectObjectDart>('SelectObject');
final _DeleteObject = _gdi32
    .lookupFunction<_DeleteObjectNative, _DeleteObjectDart>('DeleteObject');
final _CreateFontW = _gdi32.lookupFunction<_CreateFontNative, _CreateFontDart>(
  'CreateFontW',
);
final _SetTextColor = _gdi32
    .lookupFunction<_SetTextColorNative, _SetTextColorDart>('SetTextColor');
final _SetBkMode = _gdi32.lookupFunction<_SetBkModeNative, _SetBkModeDart>(
  'SetBkMode',
);
final _GetTextExtentPoint32W = _gdi32
    .lookupFunction<_GetTextExtentNative, _GetTextExtentDart>(
      'GetTextExtentPoint32W',
    );
final _CreatePen = _gdi32.lookupFunction<_CreatePenNative, _CreatePenDart>(
  'CreatePen',
);
final _MoveToEx = _gdi32.lookupFunction<_MoveToExNative, _MoveToExDart>(
  'MoveToEx',
);
final _LineTo = _gdi32.lookupFunction<_LineToNative, _LineToDart>('LineTo');

// ── 图层（每层一个"白色=覆盖率"的 32bpp DIB）──────────────────────

class _Layer {
  _Layer(this.width, this.height)
    : memDc = 0,
      bitmap = 0,
      bits = nullptr,
      pixels = null {
    final int screenDc = _userGetDc(0);
    memDc = _CreateCompatibleDc(screenDc);
    final Pointer<_BitmapInfoHeader> info = calloc<_BitmapInfoHeader>();
    info.ref
      ..biSize = sizeOf<_BitmapInfoHeader>()
      ..biWidth = width
      // 负高度 = 自上而下，省得算行序
      ..biHeight = -height
      ..biPlanes = 1
      ..biBitCount = 32
      ..biCompression = _biRgb;
    final Pointer<Pointer<Void>> bitsPtr = calloc<Pointer<Void>>();
    bitmap = _CreateDibSection(screenDc, info, _dibRgbColors, bitsPtr, 0, 0);
    bits = bitsPtr.value;
    calloc.free(info);
    calloc.free(bitsPtr);
    _ReleaseDc(0, screenDc);
    _SelectObject(memDc, bitmap);
    pixels = bits.cast<Uint32>().asTypedList(width * height);
  }

  final int width;
  final int height;
  int memDc;
  int bitmap;
  Pointer<Void> bits;
  Uint32List? pixels;

  /// 清空（全透明）。
  void clear() => pixels?.fillRange(0, width * height, 0);

  bool get isOk => memDc != 0 && bitmap != 0 && bits != nullptr;

  void dispose() {
    if (memDc != 0) {
      _DeleteDc(memDc);
      memDc = 0;
    }
    if (bitmap != 0) {
      _DeleteObject(bitmap);
      bitmap = 0;
    }
    bits = nullptr;
    pixels = null;
  }
}

// ── 浮层本体 ──────────────────────────────────────────────────────

/// 桌面歌词浮层（进程内单例）。
class LyricsOverlay {
  LyricsOverlay._();

  /// 单例。
  static final LyricsOverlay instance = LyricsOverlay._();

  /// 是否支持（只做 Windows；测试环境不碰原生）。
  static bool get isSupported =>
      !kIsWeb &&
      Platform.isWindows &&
      Platform.environment['FLUTTER_TEST'] != 'true';

  /// 浮层字号（第一行）。
  static const double baseFontSize = 26;

  /// 第二行相对第一行的比例。
  static const double secondLineRatio = 0.78;

  static const int _padX = 30;
  static const int _padY = 12;
  static const int _rowGap = 4;

  int _hwnd = 0;
  int _width = 0;
  int _height = 0;
  int _posX = -1;
  int _posY = -1;

  // 内容和样式
  String? _current;
  String? _second;
  int _accentRgb = 0xFFFFFF;
  bool _frame = true;
  bool _glow = false;
  double _wordProgress = 0;
  int _glassRgb = 0xFFFFFF;
  int _glassAlpha = 150;
  bool _glassVisible = false;
  bool _locked = false;
  Timer? _hoverTimer;

  // 图层
  _Layer? _mainLayer;
  _Layer? _secondLayer;
  _Layer? _oldLayer;
  _Layer? _haloLayer;
  _Layer? _glowLayer;

  // 字体（**独立于画布生命周期**，见文件头第 2 个坑）
  int _fontMain = 0;
  int _fontSecond = 0;
  int _fontPx = 0;
  String _fontFamily = 'Segoe UI';

  // 换行动效
  Timer? _animTimer;
  DateTime? _animStart;
  String? _oldText;
  bool _animating = false;

  /// 缓存的高光画笔（灰度 → HGDIOBJ），避免每秒新建上千支笔。
  final Map<int, int> _pens = <int, int>{};

  bool get isVisible => _hwnd != 0;

  /// 记一份位置（拖动后用 `moveTo` 覆盖）。
  int get positionX => _posX;
  int get positionY => _posY;

  int _hitTest(int lParam) {
    if (_locked) return _htTransparent;
    if (_hwnd == 0 || _width <= 0 || _height <= 0) return _htTransparent;
    final int screenX = _signedWord(lParam & 0xFFFF);
    final int screenY = _signedWord((lParam >> 16) & 0xFFFF);
    final Pointer<_Rect> rect = calloc<_Rect>();
    try {
      if (_GetWindowRect(_hwnd, rect) == 0) return _htTransparent;
      final int x = screenX - rect.ref.left;
      final int y = screenY - rect.ref.top;
      return _insideTextArea(x, y) ? _htCaption : _htTransparent;
    } finally {
      calloc.free(rect);
    }
  }

  static int _signedWord(int value) =>
      value & 0x8000 != 0 ? value - 0x10000 : value;

  void _startHoverWatch() {
    _hoverTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_hwnd == 0 || _width <= 0 || _height <= 0) return;
      final Pointer<_Rect> rect = calloc<_Rect>();
      final Pointer<_Point> point = calloc<_Point>();
      try {
        if (_GetWindowRect(_hwnd, rect) == 0 || _GetCursorPos(point) == 0)
          return;
        final bool inside = _insideCapsule(
          point.ref.x - rect.ref.left,
          point.ref.y - rect.ref.top,
          _width,
          _height,
          _height ~/ 2,
        );
        final bool shouldShow = !_locked && inside;
        if (shouldShow != _glassVisible) {
          _glassVisible = shouldShow;
          _render();
        }
      } finally {
        calloc.free(rect);
        calloc.free(point);
      }
    });
  }

  void _syncDraggedPosition() {
    if (_hwnd == 0) return;
    final Pointer<_Rect> rect = calloc<_Rect>();
    try {
      if (_GetWindowRect(_hwnd, rect) != 0) {
        _posX = rect.ref.left;
        _posY = rect.ref.top;
      }
    } finally {
      calloc.free(rect);
    }
  }

  // ── 窗口 ──────────────────────────────────────────────────────

  bool _ensureWindow() {
    if (_hwnd != 0) return true;
    try {
      final Pointer<Utf16> className = 'STATIC'.toNativeUtf16();
      final Pointer<Utf16> title = 'HoH lyrics'.toNativeUtf16();
      final int screenW = _GetSystemMetrics(_smCxScreen);
      final int screenH = _GetSystemMetrics(_smCyScreen);
      _hwnd = _CreateWindowExW(
        _wsExLayered | _wsExTopmost | _wsExToolWindow | _wsExNoActivate,
        className,
        title,
        _wsPopup,
        0,
        0,
        screenW.clamp(200, 4096),
        80,
        0,
        0,
        _GetModuleHandleW(nullptr),
        nullptr,
      );
      calloc.free(className);
      calloc.free(title);
      if (_hwnd == 0) {
        _log('CreateWindowExW 失败（浮层不可用）');
        return false;
      }
      // 让桌面歌词像一个可移动的无边框浮层：拖动任意空白/文字区域即可移动。
      // 原先的 WS_EX_TRANSPARENT 虽然穿透，但也让窗口永远无法移动。
      _SetWindowLongPtr(_hwnd, _gwlpWndProc, _lyricsWindowProcPtr);
      // 默认位置：贴近任务栏上方，避免桌面歌词悬得太高。
      _posX = -1;
      _posY = -1;
      _ShowWindow(_hwnd, _swShowNoActivate);
      _startHoverWatch();
      _log('浮层窗口已创建 hwnd=$_hwnd');
      return true;
    } catch (error) {
      _log('创建浮层失败（不影响播放）：$error');
      _hwnd = 0;
      return false;
    }
  }

  /// 更新内容与样式。`current` 为空 → 隐藏浮层。
  ///
  /// [second] 通常是本句翻译，没有翻译时传下一句。
  void setLines({
    required String? current,
    String? second,
    required Color accent,
    bool frame = true,
    bool glow = false,
    double fontSize = baseFontSize,
    double wordProgress = 0,
    String fontFamily = 'Segoe UI',
    int glassRgb = 0xFFFFFF,
    int glassAlpha = 150,
    bool locked = false,
  }) {
    if (!isSupported) return;
    final String? text = current?.trim();
    if (text == null || text.isEmpty) {
      hide();
      return;
    }
    if (!_ensureWindow()) return;

    final String secondText = (second ?? '').trim();
    final int fontPx = fontSize.round().clamp(14, 96);
    final int accentRgb = _rgbOf(accent);

    final bool sameContent =
        text == _current &&
        secondText == _second &&
        accentRgb == _accentRgb &&
        frame == _frame &&
        glassRgb == _glassRgb &&
        glassAlpha == _glassAlpha &&
        locked == _locked &&
        wordProgress == _wordProgress &&
        fontFamily == _fontFamily &&
        fontPx == _fontPx;
    if (sameContent && !_animating) {
      return;
    }

    final bool lineChanged = _current != null && text != _current;
    _accentRgb = accentRgb;
    _frame = frame;
    _fontPx = fontPx;
    // 兼容旧调用方，但不再运行边框高光动画。
    _glow = false;
    _wordProgress = wordProgress.clamp(0.0, 1.0);
    _fontFamily = fontFamily;
    _glassRgb = glassRgb;
    _glassAlpha = glassAlpha.clamp(0, 255);
    _locked = locked;
    if (_locked) _glassVisible = false;

    if (lineChanged) {
      // 旧的当前句 → 动效里上移淡出
      _oldText = _current;
      _current = text;
      _second = secondText;
      _startTransition();
    } else {
      _current = text;
      _second = secondText;
      _render();
    }

    _stopGlow();
  }

  /// 隐藏浮层（保留窗口，下次直接复用）。
  void hide() {
    if (_hwnd == 0) return;
    _stopGlow();
    _animTimer?.cancel();
    _animating = false;
    _oldText = null;
    _current = null;
    _second = null;
    _ShowWindow(_hwnd, _swHide);
    _glassVisible = false;
  }

  /// 彻底销毁。
  void dispose() {
    _stopGlow();
    _animTimer?.cancel();
    _hoverTimer?.cancel();
    _hoverTimer = null;
    _releaseLayers();
    _releaseFonts();
    _releasePens();
    if (_hwnd != 0) {
      _DestroyWindow(_hwnd);
      _hwnd = 0;
    }
    _current = null;
    _second = null;
  }

  // ── 字体与画布 ────────────────────────────────────────────────

  void _releaseFonts() {
    if (_fontMain != 0) {
      _DeleteObject(_fontMain);
      _fontMain = 0;
    }
    if (_fontSecond != 0) {
      _DeleteObject(_fontSecond);
      _fontSecond = 0;
    }
    _fontPx = 0;
  }

  void _releaseLayers() {
    _mainLayer?.dispose();
    _mainLayer = null;
    _secondLayer?.dispose();
    _secondLayer = null;
    _oldLayer?.dispose();
    _oldLayer = null;
    _haloLayer?.dispose();
    _haloLayer = null;
    _glowLayer?.dispose();
    _glowLayer = null;
  }

  void _ensureFonts(int fontPx) {
    if (_fontMain != 0 && _fontPx == fontPx) return;
    _releaseFonts();
    // 与 Windows 主界面的 Segoe UI 字体族保持一致；CJK 字符由系统 fallback。
    final Pointer<Utf16> family = _fontFamily.toNativeUtf16();
    _fontMain = _CreateFontW(
      -fontPx,
      0,
      0,
      0,
      _fwSemibold,
      0,
      0,
      0,
      _defaultCharset,
      _outTtPrecis,
      0,
      _cleartypeQuality,
      0,
      family,
    );
    final int secondPx = (fontPx * secondLineRatio).round().clamp(10, 80);
    _fontSecond = _CreateFontW(
      -secondPx,
      0,
      0,
      0,
      _fwNormal,
      0,
      0,
      0,
      _defaultCharset,
      _outTtPrecis,
      0,
      _cleartypeQuality,
      0,
      family,
    );
    calloc.free(family);
    _fontPx = fontPx;
  }

  /// 量一行文字的宽度。
  int _measure(String text, int font) {
    final Pointer<Utf16> ptr = text.toNativeUtf16();
    final Pointer<_Size> size = calloc<_Size>();
    try {
      final int screenDc = _userGetDc(0);
      final int dc = _CreateCompatibleDc(screenDc);
      final int old = _SelectObject(dc, font);
      final int ok = _GetTextExtentPoint32W(dc, ptr, text.length, size);
      _SelectObject(dc, old);
      _DeleteDc(dc);
      _ReleaseDc(0, screenDc);
      return ok == 0 ? 0 : size.ref.cx;
    } finally {
      calloc.free(ptr);
      calloc.free(size);
    }
  }

  /// 把一行文字以"白色覆盖率"画进某个图层（垂直居中于 [top, bottom) 区间）。
  void _drawCoverage(
    _Layer layer,
    String text,
    int font,
    int top,
    int bottom,
    int offsetY,
    int colorRgb,
  ) {
    final int dc = layer.memDc;
    _SetBkMode(dc, _transparent);
    _SetTextColor(dc, colorRgb);
    final int old = _SelectObject(dc, font);
    final Pointer<Utf16> ptr = text.toNativeUtf16();
    final Pointer<_Rect> rect = calloc<_Rect>();
    rect.ref
      ..left = _padX
      ..top = top + offsetY
      ..right = _width - _padX
      ..bottom = bottom + offsetY;
    _DrawTextW(
      dc,
      ptr,
      text.length,
      rect,
      _dtCenter | _dtVCenter | _dtSingleLine | _dtNoPrefix | _dtEndEllipsis,
    );
    calloc.free(rect);
    calloc.free(ptr);
    _SelectObject(dc, old);
  }

  // ── 渲染 ──────────────────────────────────────────────────────

  void _startTransition() {
    _animating = true;
    _animStart = DateTime.now();
    _animTimer?.cancel();
    _animTimer = Timer.periodic(_animationTick, (Timer timer) {
      final double elapsed =
          DateTime.now()
              .difference(_animStart ?? DateTime.now())
              .inMilliseconds /
          _transition.inMilliseconds;
      if (elapsed >= 1.0) {
        timer.cancel();
        _animating = false;
        _oldText = null;
        _render();
        return;
      }
      _render(progress: elapsed);
    });
  }

  /// 画一帧。[progress] 不为空时表示换行动效进行中（0~1）。
  void _render({double? progress}) {
    final String? current = _current;
    if (current == null || _hwnd == 0) return;
    final String second = _second ?? '';
    final int mainPx = _fontPx;
    final int secondPx = (mainPx * secondLineRatio).round().clamp(10, 80);
    _ensureFonts(mainPx);

    // ① 量宽度 → 决定胶囊尺寸（宽度只在换行时变，动效期间复用）
    final int screenW = _GetSystemMetrics(_smCxScreen);
    // 固定桌面歌词容器宽度：不随每句歌词首字/长度变化，避免窗口边框
    // 在短句与长句之间来回缩放，造成“定位抖动”和视觉突兀。
    final int width = ((screenW * 0.72).round()).clamp(560, 1080);
    final int rowMain = mainPx + 8;
    // 始终预留第二行，英文/中文歌词切换时窗口边框不会变高变矮。
    final int rowSecond = secondPx + 8;
    final int height = _padY * 2 + rowMain + _rowGap + rowSecond;

    final bool sizeChanged = width != _width || height != _height;
    if (sizeChanged || _mainLayer == null) {
      _releaseLayers();
      _width = width;
      _height = height;
      _mainLayer = _Layer(width, height);
      _secondLayer = _Layer(width, height);
      _oldLayer = _Layer(width, height);
      _haloLayer = _Layer(width, height);
      _glowLayer = _Layer(width, height);
      if (!_mainLayer!.isOk) {
        _log('CreateDIBSection 失败（浮层不可用）');
        _releaseLayers();
        return;
      }
    }

    final _Layer main = _mainLayer!;
    final _Layer secondLayer = _secondLayer!;
    final _Layer oldLayer = _oldLayer!;
    final _Layer halo = _haloLayer!;
    final _Layer glow = _glowLayer!;
    main.clear();
    secondLayer.clear();
    oldLayer.clear();
    halo.clear();
    glow.clear();

    // ② 画覆盖率
    final int mainTop = _padY;
    final int mainBottom = _padY + rowMain;
    final int secondTop = mainBottom + _rowGap;
    final int secondBottom = secondTop + rowSecond;

    final double p = progress ?? 1.0;
    final double eased = p * p * (3.0 - 2.0 * p);
    final bool animating = progress != null;
    // 动效：旧句上移淡出、新句从第二行升到第一行、新第二行淡入
    final int oldOffset = animating ? (-8 * eased).round() : 0;
    final int currentOffset = animating ? (8 * (1 - eased)).round() : 0;

    if (_frame) {
      // 玻璃框：只是白底 + 高光，不需要描边层
      if (_glassVisible) {
        _drawFrame(halo, glow, current: current, glowOn: _glow);
      }
    } else {
      // 只有文字：用描边层画深色小字轮廓（8 方向偏移），保证任何背景都看得清
      final String oldText = _oldText ?? '';
      for (final List<int> d in _haloOffsets) {
        _drawCoverage(
          halo,
          current,
          _fontMain,
          mainTop,
          mainBottom,
          currentOffset + d[1],
          0x00FFFFFF,
        );
        if (second.isNotEmpty) {
          _drawCoverage(
            halo,
            second,
            _fontSecond,
            secondTop,
            secondBottom,
            d[1],
            0x00FFFFFF,
          );
        }
        if (animating && oldText.isNotEmpty) {
          _drawCoverage(
            halo,
            oldText,
            _fontMain,
            mainTop,
            mainBottom,
            oldOffset + d[1],
            0x00FFFFFF,
          );
        }
      }
    }

    _drawCoverage(
      main,
      current,
      _fontMain,
      mainTop,
      mainBottom,
      currentOffset,
      0x00FFFFFF,
    );
    if (second.isNotEmpty) {
      _drawCoverage(
        secondLayer,
        second,
        _fontSecond,
        secondTop,
        secondBottom,
        0,
        0x00FFFFFF,
      );
    }
    if (animating && (_oldText ?? '').isNotEmpty) {
      _drawCoverage(
        oldLayer,
        _oldText!,
        _fontMain,
        mainTop,
        mainBottom,
        oldOffset,
        0x00FFFFFF,
      );
    }

    _composite(
      main: main,
      second: secondLayer,
      old: oldLayer,
      halo: halo,
      glow: glow,
      progress: p,
      animating: animating,
    );
    _push();
  }

  /// 描边偏移（8 方向）。
  static const List<List<int>> _haloOffsets = <List<int>>[
    <int>[0, -1],
    <int>[0, 1],
    <int>[-1, 0],
    <int>[1, 0],
    <int>[-1, -1],
    <int>[1, -1],
    <int>[-1, 1],
    <int>[1, 1],
  ];

  /// 玻璃框：深色半透明胶囊 + 边框高光（画在 halo/glow 两个图层里）。
  void _drawFrame(
    _Layer frameLayer,
    _Layer glowLayer, {
    required String current,
    required bool glowOn,
  }) {
    // 深色玻璃基底：和主界面的深色液态玻璃一致，轮廓留给彩色边框高光。
    final Uint32List? framePixels = frameLayer.pixels;
    if (framePixels == null) return;
    final int radius = _height ~/ 2;
    for (int y = 0; y < _height; y++) {
      final int rowStart = y * _width;
      for (int x = 0; x < _width; x++) {
        if (_insideCapsule(x, y, _width, _height, radius)) {
          framePixels[rowStart + x] = 0x00FFFFFF;
        }
      }
    }

    // 边框不再绘制移动高光。静态半透明胶囊由主界面动画层负责“播放感”，
    // 独立桌面歌词只做稳定的句间过渡，避免 GDI 高频描边带来的抖动。
  }

  /// 按灰度取（并缓存）一支 2px 实心圆头画笔。
  int _pen(int gray) {
    final int key = gray.clamp(0, 255);
    final int? cached = _pens[key];
    if (cached != null) return cached;
    final int handle = _CreatePen(_psSolid, 2, key * 0x010101);
    _pens[key] = handle;
    return handle;
  }

  void _releasePens() {
    for (final int handle in _pens.values) {
      if (handle != 0) _DeleteObject(handle);
    }
    _pens.clear();
  }

  /// 胶囊轮廓采样点（x0,y0,x1,y1,...）。
  List<double> _capsulePath(int radius) {
    final List<double> pts = <double>[];
    const int arcSteps = 10;
    final double w = _width.toDouble();
    final double h = _height.toDouble();
    final double r = radius.toDouble();
    // 上边：左 → 右
    final int edgeSteps = math.max(8, (_width / 26).round());
    for (int i = 0; i <= edgeSteps; i++) {
      pts.add(r + (w - 2 * r) * i / edgeSteps);
      pts.add(0.5);
    }
    // 右半圆
    for (int i = 1; i <= arcSteps; i++) {
      final double a = -math.pi / 2 + math.pi * i / arcSteps;
      pts.add(w / 2 + (w / 2 - r) + r * math.cos(a));
      pts.add(h / 2 + r * math.sin(a));
    }
    // 下边：右 → 左
    for (int i = 0; i <= edgeSteps; i++) {
      pts.add(w - r - (w - 2 * r) * i / edgeSteps);
      pts.add(h - 0.5);
    }
    // 左半圆
    for (int i = 1; i <= arcSteps; i++) {
      final double a = math.pi / 2 + math.pi * i / arcSteps;
      pts.add(r + r * math.cos(a));
      pts.add(h / 2 + r * math.sin(a));
    }
    return pts;
  }

  /// 合成 premultiplied BGRA 并推给系统。
  void _composite({
    required _Layer main,
    required _Layer second,
    required _Layer old,
    required _Layer halo,
    required _Layer glow,
    required double progress,
    required bool animating,
  }) {
    final Uint32List? out = main.pixels;
    final Uint32List? secondPx = second.pixels;
    final Uint32List? oldPx = old.pixels;
    final Uint32List? haloPx = halo.pixels;
    final Uint32List? glowPx = glow.pixels;
    if (out == null ||
        secondPx == null ||
        oldPx == null ||
        haloPx == null ||
        glowPx == null) {
      return;
    }

    // 颜色（都按 premultiplied 计算）
    final bool frame = _frame && _glassVisible;
    // 桌面歌词沿用主 UI 的互补玻璃颜色和透明度。
    final int frameAlpha = _glassAlpha;
    final int mainR;
    final int mainG;
    final int mainB;
    final int secondR;
    final int secondG;
    final int secondB;
    final int haloR;
    final int haloG;
    final int haloB;
    if (frame) {
      mainR = 248;
      mainG = 246;
      mainB = 255;
      secondR = 190;
      secondG = 186;
      secondB = 211;
      haloR = 0;
      haloG = 0;
      haloB = 0;
    } else {
      // 只有文字：白字 + 深色描边
      mainR = 255;
      mainG = 255;
      mainB = 255;
      secondR = 226;
      secondG = 226;
      secondB = 232;
      haloR = 0;
      haloG = 0;
      haloB = 0;
    }
    final int mainAlpha = 255;
    final int secondAlpha = frame ? 210 : 200;
    final int haloAlpha = frame ? 0 : 200;
    final double transitionProgress =
        progress * progress * (3.0 - 2.0 * progress);
    final int oldAlpha = animating
        ? ((1.0 - transitionProgress) * 255).round()
        : 0;
    final int textWidth = _measure(_current ?? '', _fontMain);
    final int textLeft = ((_width - textWidth) ~/ 2).clamp(0, _width);
    final int revealRight = textLeft + (textWidth * _wordProgress).round();

    for (int i = 0; i < _width * _height; i++) {
      int r = 0;
      int g = 0;
      int b = 0;
      int a = 0;

      void over(int cr, int cg, int cb, int alpha) {
        if (alpha <= 0) return;
        // 覆盖率→颜色（premultiplied），再叠到当前结果上
        r = (cr * alpha + r * (255 - alpha)) ~/ 255;
        g = (cg * alpha + g * (255 - alpha)) ~/ 255;
        b = (cb * alpha + b * (255 - alpha)) ~/ 255;
        a = alpha + a * (255 - alpha) ~/ 255;
      }

      // ① 玻璃框底（深色半透明）
      if (frame) {
        final int cov = haloPx[i] & 0xFF; // 框的覆盖率
        if (cov > 0) {
          over(
            ((_glassRgb >> 16) & 0xFF),
            ((_glassRgb >> 8) & 0xFF),
            _glassRgb & 0xFF,
            cov * frameAlpha ~/ 255,
          );
        }
      }
      // ② 边框高光
      final int glowCov = glowPx[i] & 0xFF;
      if (glowCov > 0) {
        final int peak = _lerpToWhite(_accentRgb, 0.4);
        over((peak >> 16) & 0xFF, (peak >> 8) & 0xFF, peak & 0xFF, glowCov);
      }
      // ③ 深色描边（只有关掉玻璃框时才画）
      if (haloAlpha > 0) {
        final int cov = haloPx[i] & 0xFF;
        if (cov > 0) over(haloR, haloG, haloB, cov * haloAlpha ~/ 255);
      }
      // ④ 旧句（淡出）
      if (oldAlpha > 0) {
        final int cov = oldPx[i] & 0xFF;
        if (cov > 0) over(mainR, mainG, mainB, cov * oldAlpha ~/ 255);
      }
      // ⑤ 当前句
      final int mainCov = out[i] & 0xFF;
      if (mainCov > 0) {
        final bool revealed =
            frame && (i % _width) >= textLeft && (i % _width) <= revealRight;
        final int r = revealed ? ((_accentRgb >> 16) & 0xFF) : mainR;
        final int g = revealed ? ((_accentRgb >> 8) & 0xFF) : mainG;
        final int b = revealed ? (_accentRgb & 0xFF) : mainB;
        over(r, g, b, mainCov * mainAlpha ~/ 255);
      }
      // ⑥ 第二行
      final int secondCov = secondPx[i] & 0xFF;
      if (secondCov > 0) {
        over(secondR, secondG, secondB, secondCov * secondAlpha ~/ 255);
      }

      out[i] =
          (b & 0xFF) |
          ((g & 0xFF) << 8) |
          ((r & 0xFF) << 16) |
          ((a & 0xFF) << 24);
    }
  }

  /// 把画布推给窗口。
  void _push() {
    final _Layer? layer = _mainLayer;
    if (layer == null || _hwnd == 0) return;
    final int screenW = _GetSystemMetrics(_smCxScreen);
    final int workBottom = _workAreaBottom();
    final int x = _posX >= 0
        ? _posX
        : ((screenW - _width) ~/ 2).clamp(0, screenW);
    final int y = _posY >= 0
        ? _posY
        : (workBottom - _height - 12).clamp(0, workBottom);
    _posX = x;
    _posY = y;

    _SetWindowPos(
      _hwnd,
      _hwndTopmost,
      x,
      y,
      _width,
      _height,
      _swpNoActivate | _swpShowWindow,
    );

    final int screenDc = _userGetDc(0);
    final Pointer<_Point> dst = calloc<_Point>();
    dst.ref
      ..x = x
      ..y = y;
    final Pointer<_Size> size = calloc<_Size>();
    size.ref
      ..cx = _width
      ..cy = _height;
    final Pointer<_Point> src = calloc<_Point>();
    src.ref
      ..x = 0
      ..y = 0;
    final Pointer<_BlendFunction> blend = calloc<_BlendFunction>();
    blend.ref
      ..blendOp = _acSrcOver
      ..blendFlags = 0
      ..sourceConstantAlpha = 255
      ..alphaFormat = _acSrcAlpha;
    final int ok = _UpdateLayeredWindow(
      _hwnd,
      screenDc,
      dst,
      size,
      layer.memDc,
      src,
      0,
      blend,
      _ulwAlpha,
    );
    calloc.free(dst);
    calloc.free(size);
    calloc.free(src);
    calloc.free(blend);
    _ReleaseDc(0, screenDc);
    if (ok == 0) _log('UpdateLayeredWindow 返回 0（没画上去）');
  }

  // ── 玻璃框动效 ───────────────────────────────────────────────

  // 保留旧接口，避免外部调用方改变；新的桌面歌词不再运行高光定时器。
  void _stopGlow() {}

  // ── 小工具 ────────────────────────────────────────────────────

  static bool _insideCapsule(int x, int y, int width, int height, int radius) {
    final int cx = x < radius
        ? radius
        : (x >= width - radius ? width - radius - 1 : x);
    final int cy = y < radius
        ? radius
        : (y >= height - radius ? height - radius - 1 : y);
    final int dx = x - cx;
    final int dy = y - cy;
    if (dx == 0 && dy == 0) return true;
    return dx * dx + dy * dy <= radius * radius;
  }

  bool _insideTextArea(int x, int y) {
    if (!_insideCapsule(x, y, _width, _height, _height ~/ 2)) return false;
    if (_fontMain == 0 || _fontSecond == 0) return false;
    final int mainHeight = math.max(18, _fontPx);
    final int secondHeight = math.max(14, (_fontPx * secondLineRatio).round());
    final int mainWidth = _measure(_current ?? '', _fontMain);
    final int secondWidth = _measure(_second ?? '', _fontSecond);
    final int textWidth = math.min(
      _width - _padX,
      math.max(mainWidth, secondWidth) + 24,
    );
    final int left = (_width - textWidth) ~/ 2;
    final bool inMain = y >= _padY - 6 && y <= _padY + mainHeight + 6;
    final int secondTop = _padY + mainHeight + _rowGap;
    final bool inSecond =
        y >= secondTop - 6 && y <= secondTop + secondHeight + 6;
    return x >= left - 8 && x <= left + textWidth + 8 && (inMain || inSecond);
  }

  static int _rgbOf(Color color) {
    final int r = (color.r * 255).round() & 0xFF;
    final int g = (color.g * 255).round() & 0xFF;
    final int b = (color.b * 255).round() & 0xFF;
    return (r << 16) | (g << 8) | b;
  }

  /// 往深里压（兼容旧样式计算）。
  static int _darken(int rgb, double amount) {
    final int r = ((rgb >> 16) & 0xFF) * (1 - amount) ~/ 1;
    final int g = ((rgb >> 8) & 0xFF) * (1 - amount) ~/ 1;
    final int b = (rgb & 0xFF) * (1 - amount) ~/ 1;
    return (r.clamp(0, 255) << 16) | (g.clamp(0, 255) << 8) | b.clamp(0, 255);
  }

  /// 往白里提（高光峰值）。
  static int _lerpToWhite(int rgb, double amount) {
    int mix(int c) => (c + (255 - c) * amount).round().clamp(0, 255);
    return (mix((rgb >> 16) & 0xFF) << 16) |
        (mix((rgb >> 8) & 0xFF) << 8) |
        mix(rgb & 0xFF);
  }
}

/// 调试用：把固定文字推给浮层，方便无播放时截图验证。
///
/// 环境变量 `HOH_LYRICS_DEMO`（仅 Debug）：值就是显示的文字，
/// 用 `|` 分隔第二行，例如 `HOH_LYRICS_DEMO="第一行|第二行"`。
(String, String?)? resolveDebugLyricsDemo() {
  if (kReleaseMode) return null;
  final String? demo = Platform.environment['HOH_LYRICS_DEMO'];
  if (demo == null || demo.trim().isEmpty) return null;
  final List<String> parts = demo.split('|');
  final String first = parts.first.trim();
  if (first.isEmpty) return null;
  final String? second = parts.length > 1 && parts[1].trim().isNotEmpty
      ? parts[1].trim()
      : null;
  return (first, second);
}

/// 把桌面歌词浮层接到应用上。
class LyricsOverlayHost extends ConsumerStatefulWidget {
  const LyricsOverlayHost({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  /// 当前平台是否支持。
  static bool get isSupported => LyricsOverlay.isSupported;

  @override
  ConsumerState<LyricsOverlayHost> createState() => _LyricsOverlayHostState();
}

class _LyricsOverlayHostState extends ConsumerState<LyricsOverlayHost> {
  /// 上一次推给浮层的内容（用来跳过重复更新）。
  String? _pushedKey;

  @override
  void dispose() {
    LyricsOverlay.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final LyricsStyle style =
        ref.watch(lyricsStyleProvider).value ?? const LyricsStyle();
    // 调试模式强制打开，方便不播放时截图验证
    final (String, String?)? demo = resolveDebugLyricsDemo();
    final bool enabled = demo != null || style.desktopOverlay;
    final String? current = demo?.$1 ?? ref.watch(currentLyricLineProvider);
    final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
    final int lyricIndex = ref.watch(currentLyricIndexProvider);
    final Duration position =
        ref.watch(playbackPositionProvider).value ?? Duration.zero;
    double wordProgress = 0;
    if (lyrics != null && lyricIndex >= 0 && lyricIndex < lyrics.lines.length) {
      final Duration start = lyrics.lines[lyricIndex].time;
      final Duration end = lyricIndex + 1 < lyrics.lines.length
          ? lyrics.lines[lyricIndex + 1].time
          : start + const Duration(seconds: 5);
      final int span = end.inMilliseconds - start.inMilliseconds;
      if (span > 0) {
        wordProgress = ((position.inMilliseconds - start.inMilliseconds) / span)
            .clamp(0.0, 1.0);
      }
    }
    // 第二行：优先翻译，没有翻译就显示下一句
    final String? second =
        demo?.$2 ??
        ref.watch(currentLyricTranslationProvider) ??
        ref.watch(nextLyricLineProvider);
    final BlurConfig glassConfig = ref.watch(blurConfigProvider);
    final bool animations = glassConfig.animationsEnabled;
    final HSVColor glassHsv = HSVColor.fromColor(accent.primary);
    final Color glassColor = glassHsv
        .withHue((glassHsv.hue + 180) % 360)
        .withSaturation(glassConfig.glassSaturation)
        .withValue((1.0 - glassConfig.glassTone * 0.72).clamp(0.22, 1.0))
        .toColor();
    final int glassRgb =
        (glassColor.r * 255).round() << 16 |
        (glassColor.g * 255).round() << 8 |
        (glassColor.b * 255).round();
    final int glassAlpha = ((0.02 + 0.18 * glassConfig.tintOpacity) * 255)
        .round();

    final String key = <String>[
      enabled ? '1' : '0',
      animations ? '1' : '0',
      style.overlayFrame ? '1' : '0',
      style.overlayLocked ? '1' : '0',
      current ?? '',
      (wordProgress * 10).round().toString(),
      second ?? '',
      accent.primary.toARGB32().toRadixString(16),
      style.fontFamily.name,
    ].join('|');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!enabled || !animations || current == null || current.isEmpty) {
        if (_pushedKey != null) {
          _pushedKey = null;
          LyricsOverlay.instance.hide();
        }
        return;
      }
      if (key == _pushedKey) return;
      _pushedKey = key;
      LyricsOverlay.instance.setLines(
        current: current,
        second: second,
        accent: accent.primary,
        frame: style.overlayFrame,
        locked: style.overlayLocked,
        // 桌面歌词采用主流播放器的稳定 HUD 动画，不运行边框高光。
        glow: false,
        fontSize: LyricsOverlay.baseFontSize,
        wordProgress: (wordProgress * 10).round() / 10,
        // 桌面歌词不再读取全局程序字体，固定使用 Windows 系统默认 UI 字体。
        // 原生 GDI 不能读取 Flutter assets 中的字体文件，桌面歌词暂以
        // Windows 系统 UI 字体绘制；播放页歌词使用内置耀圆体。
        fontFamily: 'Segoe UI',
        glassRgb: glassRgb,
        glassAlpha: glassAlpha,
      );
    });

    return widget.child;
  }
}
