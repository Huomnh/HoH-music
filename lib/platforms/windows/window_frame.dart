/// window_frame.dart
///
/// 给无边框窗口做圆角外框。
///
/// 背景：`setAsFrameless()` 之后窗口是方的。Windows 11 可以用 DWM 的
/// `DWMWA_WINDOW_CORNER_PREFERENCE` 让系统自己圆角，但 **Windows 10 不支持**。
/// 本机是 Windows 10 22H2，所以走 `SetWindowRgn` —— 用圆角矩形区域裁剪窗口。
///
/// 代价：区域裁剪**没有抗锯齿**，边缘是硬的；圆角半径不宜太大。
/// 放大 / 还原时需要重算区域，所以监听窗口尺寸变化。
///
/// 全部走 FFI 直接调 Win32，不引入新依赖。
library;

import 'dart:async';
// dart:ffi 也有一个 Size（Win32 结构体用的），会和 dart:ui 的 Size 撞名
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

// ── 函数签名 ──────────────────────────────────────────────────────

typedef _CreateRoundRectRgnNative = IntPtr Function(
  Int32,
  Int32,
  Int32,
  Int32,
  Int32,
  Int32,
);
typedef _CreateRoundRectRgnDart = int Function(int, int, int, int, int, int);

typedef _SetWindowRgnNative = Int32 Function(IntPtr, IntPtr, Int32);
typedef _SetWindowRgnDart = int Function(int, int, int);

typedef _DeleteObjectNative = Int32 Function(IntPtr);
typedef _DeleteObjectDart = int Function(int);

typedef _GetWindowRectNative = Int32 Function(IntPtr, Pointer<_Rect>);
typedef _GetWindowRectDart = int Function(int, Pointer<_Rect>);

/// `FindWindowW(lpClassName, lpWindowName)`——按窗口标题查找顶层窗口。
/// 传空类名 + 精确标题即可，比枚举窗口简单得多，也不需要原生回调。
typedef _FindWindowNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowDart = int Function(Pointer<Utf16>, Pointer<Utf16>);

/// Win32 RECT。
///
/// Dart 里声明 FFI 结构体的规则：字段必须是 `external` + `@Int32()` 注解，
/// 不能写成普通的 `Int32 left;`（那会被当成 Dart 字段而编译失败）。
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

// ── Win32 绑定 ────────────────────────────────────────────────────

final class _Win32 {
  _Win32._({
    required this.createRoundRectRgn,
    required this.setWindowRgn,
    required this.deleteObject,
    required this.getWindowRect,
    required this.findWindow,
  });

  final _CreateRoundRectRgnDart createRoundRectRgn;
  final _SetWindowRgnDart setWindowRgn;
  final _DeleteObjectDart deleteObject;
  final _GetWindowRectDart getWindowRect;
  final _FindWindowDart findWindow;

  static _Win32? _instance;

  static _Win32? get instance {
    if (!Platform.isWindows) return null;
    if (_instance != null) return _instance;

    try {
      final DynamicLibrary gdi32 = DynamicLibrary.open('gdi32.dll');
      final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');

      _instance = _Win32._(
        createRoundRectRgn: gdi32
            .lookupFunction<_CreateRoundRectRgnNative, _CreateRoundRectRgnDart>(
              'CreateRoundRectRgn',
            ),
        setWindowRgn: user32
            .lookupFunction<_SetWindowRgnNative, _SetWindowRgnDart>(
              'SetWindowRgn',
            ),
        deleteObject: gdi32
            .lookupFunction<_DeleteObjectNative, _DeleteObjectDart>(
              'DeleteObject',
            ),
        getWindowRect: user32
            .lookupFunction<_GetWindowRectNative, _GetWindowRectDart>(
              'GetWindowRect',
            ),
        // 显式用 W 版本，避免 CharSet 推断差异
        findWindow: user32.lookupFunction<_FindWindowNative, _FindWindowDart>(
          'FindWindowW',
        ),
      );
    } catch (error) {
      _log('failed to load Win32: $error');
      return null;
    }
    return _instance;
  }
}

/// 窗口圆角处理。
abstract final class WindowFrame {
  /// 圆角半径（物理像素）。区域裁剪无抗锯齿，别设太大。
  /// 主窗口与紧凑窗口统一使用更柔和的液态玻璃圆角。
  static const int cornerRadius = 22;

  /// 用于查找本进程主窗口的标题候选。
  ///
  /// ⚠️ 必须用**原生窗口标题**，不是 `MaterialApp.title`。
  /// Windows runner 建窗口时用的是 `windows/runner/main.cpp` 里的名字，
  /// 那个才是 Win32 层面真正的窗口标题。
  ///
  /// 注意：可执行名 `hoh_music` 与显示名 `HoH music` 是两回事，
  /// 这里两个都试，哪个先命中用哪个。
  static const List<String> windowTitleCandidates = <String>[
    'HoH music',
    'hoh_music',
  ];

  static bool _applied = false;
  static int? _hwnd;
  static _FrameListener? _listener;

  /// 最近一次由 Flutter 视口推来的物理尺寸，用来避免重复设置区域。
  static Size? _lastViewport;

  /// `windowManager.getId()` 的最近一次取值，作为句柄查找的兜底。
  static int _windowManagerId = 0;

  /// 是否可用。
  static bool get isSupported => Platform.isWindows && _Win32.instance != null;

  /// 依据 **Flutter 视口尺寸**重新应用圆角区域。
  ///
  /// ⚠️ 踩坑（0.0.9 修）：原来只靠 window_manager 的 resize 事件刷新区域，
  /// 实测在**外部改变窗口尺寸**（例如脚本 `MoveWindow`）时收不到事件，
  /// 区域会一直停留在启动尺寸 1280x800 —— 于是窗口被裁剪，
  /// 右下角整块界面看不见（截图表现为"界面比窗口小一圈，底下露出桌面"）。
  ///
  /// 现在改由 Flutter 自己的视口尺寸驱动：窗口客户区多大，
  /// Flutter 的 `physicalSize` 就是多大，这是权威来源，不依赖事件是否到达。
  static Future<void> syncToViewport(Size physicalSize) async {
    if (!isSupported || physicalSize.isEmpty) return;
    // 尺寸没变且已经应用过，就不用再调 Win32
    if (_applied && _lastViewport == physicalSize) return;
    _lastViewport = physicalSize;

    try {
      final int? hwnd = _hwnd ??= _findOwnHwnd();
      if (hwnd == null) {
        _log('syncToViewport: hwnd not found, skip');
        return;
      }

      final bool maximized = await windowManager.isMaximized();
      _setRegion(
        hwnd,
        physicalSize.width.round(),
        physicalSize.height.round(),
        enabled: !maximized,
      );
      _applied = true;
    } catch (error) {
      _log('syncToViewport failed: $error');
    }
  }

  /// 应用圆角区域，并挂上尺寸变化监听。
  ///
  /// 需要在窗口已经显示之后调用——`SetWindowRgn` 依赖真实的窗口尺寸。
  static Future<void> applyRoundedCorners() async {
    if (!isSupported) return;

    try {
      // 记录 window_manager 给的 id，供句柄查找兜底使用
      try {
        _windowManagerId = await windowManager.getId();
      } catch (_) {
        _windowManagerId = 0;
      }

      final int? hwnd = _hwnd ??= _findOwnHwnd();
      if (hwnd == null) {
        _log('hwnd not found, skip rounding');
        return;
      }

      final bool maximized = await windowManager.isMaximized();

      // 用 Win32 自己的 GetWindowRect 取尺寸，而不是 windowManager.getSize()：
      // 前者是物理像素，正是 SetWindowRgn 需要的；后者是 Flutter 逻辑像素，
      // 在高 DPI 下会偏小。
      final _Win32? api = _Win32.instance;
      if (api == null) return;

      final Pointer<_Rect> rect = calloc<_Rect>();
      try {
        if (api.getWindowRect(hwnd, rect) == 0) {
          _log('GetWindowRect failed hwnd=$hwnd');
          return;
        }
        final int w = rect.ref.right - rect.ref.left;
        final int h = rect.ref.bottom - rect.ref.top;
        _log('window physical size ${w}x$h (maximized=$maximized)');

        // 最大化时不圆角——那会露出桌面，看起来像没铺满
        _setRegion(hwnd, w, h, enabled: !maximized);
        _applied = true;
      } finally {
        calloc.free(rect);
      }

      // 首次成功后挂上监听，之后每次尺寸变化自动重算
      _attachListener();
    } catch (error) {
      _log('applyRoundedCorners failed: $error');
    }
  }

  /// 窗口尺寸变化后重算区域。
  static Future<void> refresh() async {
    if (!isSupported || !_applied) return;
    try {
      await applyRoundedCorners();
    } catch (error) {
      _log('refresh failed (ignored): $error');
    }
  }

  /// 移除监听。
  static void detach() {
    final _FrameListener? listener = _listener;
    if (listener == null) return;
    try {
      windowManager.removeListener(listener);
    } catch (_) {
      // 忽略
    }
    _listener = null;
  }

  /// 定位本应用的主窗口句柄。
  ///
  /// 依次尝试两条路，并做**有效性校验**（能否 `GetWindowRect` 取到尺寸）：
  /// 1. `FindWindowW` 按原生窗口标题查找——最可靠，但要求窗口是顶层窗口；
  /// 2. `windowManager.getId()` 的返回值直接当 HWND 用——该值在平台上语义不同，
  ///    不保证是 HWND，所以只作为兜底，且必须通过校验才采用。
  ///
  /// 两条都失败时返回 null，调用方跳过圆角（界面仍可用）。
  static int? _findOwnHwnd() {
    final _Win32? api = _Win32.instance;
    if (api == null) return null;

    // ① 按标题查
    final Pointer<Utf16> emptyClass = ''.toNativeUtf16();
    try {
      for (final String candidate in windowTitleCandidates) {
        final Pointer<Utf16> title = candidate.toNativeUtf16();
        try {
          final int hwnd = api.findWindow(emptyClass, title);
          if (hwnd != 0 && _isUsableHwnd(api, hwnd)) {
            _log('hwnd via FindWindowW("$candidate") = $hwnd');
            return hwnd;
          }
        } finally {
          calloc.free(title);
        }
      }
      _log('FindWindowW miss for: ${windowTitleCandidates.join(" / ")}');
    } finally {
      calloc.free(emptyClass);
    }

    // ② 兜底：windowManager 给的 id
    final int wmId = _windowManagerId;
    if (wmId != 0 && _isUsableHwnd(api, wmId)) {
      _log('hwnd via windowManager.getId() = $wmId');
      return wmId;
    }

    _log('no usable hwnd found');
    return null;
  }

  /// 校验句柄是不是一个真实、可查询的窗口。
  static bool _isUsableHwnd(_Win32 api, int hwnd) {
    final Pointer<_Rect> rect = calloc<_Rect>();
    try {
      return api.getWindowRect(hwnd, rect) != 0;
    } catch (_) {
      return false;
    } finally {
      calloc.free(rect);
    }
  }

  static void _attachListener() {
    if (_listener != null) return;
    try {
      final _FrameListener listener = _FrameListener(refresh);
      windowManager.addListener(listener);
      _listener = listener;
    } catch (error) {
      _log('addListener failed (ignored): $error');
    }
  }

  static void _setRegion(
    int hwnd,
    int width,
    int height, {
    required bool enabled,
  }) {
    final _Win32? api = _Win32.instance;
    if (api == null) return;
    if (width <= 0 || height <= 0) {
      _log('bad size ${width}x$height, skip');
      return;
    }

    if (!enabled) {
      final int cleared = api.setWindowRgn(hwnd, 0, 1);
      _log('clear region hwnd=$hwnd → $cleared');
      return;
    }

    // 右 / 下边界要 +1，否则最外一列像素会被裁掉
    final int region = api.createRoundRectRgn(
      0,
      0,
      width + 1,
      height + 1,
      cornerRadius * 2,
      cornerRadius * 2,
    );
    if (region == 0) {
      _log('CreateRoundRectRgn failed');
      return;
    }

    // SetWindowRgn 成功后，区域归系统所有，**不能**再 DeleteObject，
    // 否则窗口销毁时会引用野句柄。返回 0 表示失败，此时要自己释放。
    final int ok = api.setWindowRgn(hwnd, region, 1);
    _log(
      '[WindowFrame] SetWindowRgn hwnd=$hwnd ${width}x$height '
      '半径=$cornerRadius → $ok ${ok != 0 ? "(成功)" : "(失败，已释放)"}',
    );
    if (ok == 0) api.deleteObject(region);
  }
}

/// 只关心尺寸变化的窗口监听器。
///
/// 单独做成一个类，而不是让页面 State 去 mixin：
/// `WindowListener` 是 `abstract mixin class`，而 Dart 不允许 mixin 带 `with` 子句，
/// 想在别的 mixin 里复用它并不方便。独立对象更简单可控。
class _FrameListener with WindowListener {
  _FrameListener(this.onChanged);

  final VoidCallback onChanged;

  @override
  void onWindowResize() => onChanged();

  /// Windows 上尺寸变化更可靠地走这个回调，两个都接上。
  @override
  void onWindowResized() => onChanged();

  @override
  void onWindowMaximize() => onChanged();

  @override
  void onWindowUnmaximize() => onChanged();

  @override
  void onWindowRestore() => onChanged();
}

/// 让窗口圆角区域跟随 Flutter 视口尺寸。
///
/// 挂在 `MaterialApp` 内层即可（不需要可见的 UI）。它监听
/// [WidgetsBindingObserver.didChangeMetrics] —— 窗口被拖动 / 缩放 /
/// 最大化时 Flutter 的视口尺寸都会变，这里就重新设一次区域。
///
/// 见 [WindowFrame.syncToViewport] 里记的那个踩坑：window_manager 的
/// resize 事件在外部改变尺寸时收不到，靠它刷新区域会把界面裁掉。
class WindowFrameSync extends StatefulWidget {
  const WindowFrameSync({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  /// 只在 Windows 上需要（其它平台没有这套区域裁剪）。
  static bool get supported => WindowFrame.isSupported;

  @override
  State<WindowFrameSync> createState() => _WindowFrameSyncState();
}

class _WindowFrameSyncState extends State<WindowFrameSync>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 首帧后再同步一次：此时窗口已经显示，尺寸也是真实的
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeMetrics() => _sync();

  void _sync() {
    if (!mounted) return;
    // 不显式写 FlutterView 类型：widgets.dart 里没导出它，交给类型推断
    final view =
        View.maybeOf(context) ??
        WidgetsBinding.instance.platformDispatcher.implicitView;
    final Size? size = view?.physicalSize;
    if (size == null) return;
    unawaited(WindowFrame.syncToViewport(size));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Immediate diagnostic output.
///
/// Deliberately not debugPrint: that one is throttled and drops lines during
/// early startup, which previously made it look like a setup step never ran.
void _log(String message) {
  stderr.writeln('[WindowFrame] $message');
}
