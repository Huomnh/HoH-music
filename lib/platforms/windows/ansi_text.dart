/// ansi_text.dart
///
/// 系统 ANSI 编码文本的解码（Windows）。
///
/// 背景：中文 Windows 上大量 `.lrc` 歌词是 **GBK / ANSI** 编码，而不是 UTF-8；
/// Dart 的 `dart:convert` 只自带 UTF-8 / ASCII / Latin-1，硬按 UTF-8 读会抛异常、
/// 按 Latin-1 读则满屏乱码（「再见」→「ÔÙ¼û」）。
///
/// 这里借 Win32 自己的 `MultiByteToWideChar` 按**系统 ANSI 代码页**解码，
/// 不引入任何新依赖：
///
/// ```dart
/// final int count = MultiByteToWideChar(codePage, 0, bytesPtr, length, nullptr, 0);
/// MultiByteToWideChar(codePage, 0, bytesPtr, length, outPtr, count);
/// // outPtr 里是 UTF-16，直接 String.fromCharCodes 即可
/// ```
///
/// 代码页用 `GetACP()` 取（中文系统是 936），而不是写死 936 ——
/// 日文 / 韩文系统的歌词也能正确解出来。
///
/// 非 Windows、或任何一步失败时返回 `null`，由调用方决定降级方式。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _GetAcpNative = Uint32 Function();
typedef _GetAcpDart = int Function();

typedef _MultiByteToWideCharNative = Int32 Function(
  Uint32 codePage,
  Uint32 flags,
  Pointer<Uint8> bytes,
  Int32 byteCount,
  Pointer<Uint16> out,
  Int32 outCount,
);
typedef _MultiByteToWideCharDart = int Function(
  int codePage,
  int flags,
  Pointer<Uint8> bytes,
  int byteCount,
  Pointer<Uint16> out,
  int outCount,
);

class _Win32Text {
  _Win32Text._(this.getAcp, this.multiByteToWideChar);

  final _GetAcpDart getAcp;
  final _MultiByteToWideCharDart multiByteToWideChar;

  static _Win32Text? _instance;
  static bool _tried = false;

  static _Win32Text? get instance {
    if (_tried) return _instance;
    _tried = true;
    if (!Platform.isWindows) return null;

    try {
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      _instance = _Win32Text._(
        kernel32.lookupFunction<_GetAcpNative, _GetAcpDart>('GetACP'),
        kernel32.lookupFunction<
          _MultiByteToWideCharNative,
          _MultiByteToWideCharDart
        >('MultiByteToWideChar'),
      );
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }
}

/// 按系统 ANSI 代码页解码字节；非 Windows 或失败时返回 `null`。
String? decodeSystemAnsi(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final _Win32Text? api = _Win32Text.instance;
  if (api == null) return null;

  Pointer<Uint8> input = nullptr;
  Pointer<Uint16> output = nullptr;
  try {
    input = calloc<Uint8>(bytes.length);
    for (int i = 0; i < bytes.length; i++) {
      input[i] = bytes[i] & 0xFF;
    }

    final int codePage = api.getAcp();
    final int count = api.multiByteToWideChar(
      codePage,
      0,
      input,
      bytes.length,
      nullptr,
      0,
    );
    if (count <= 0) return null;

    output = calloc<Uint16>(count);
    final int written = api.multiByteToWideChar(
      codePage,
      0,
      input,
      bytes.length,
      output,
      count,
    );
    if (written <= 0) return null;

    return String.fromCharCodes(output.asTypedList(written));
  } catch (_) {
    return null;
  } finally {
    if (input != nullptr) calloc.free(input);
    if (output != nullptr) calloc.free(output);
  }
}
