/// source_widgets.dart
///
/// 音源相关页面的公共小组件（和 WebDAV 页保持同一套视觉语言）：
/// 小节标题、输入框、提示、状态行、封面小方块。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';

/// 小节标题（`SOURCES` / `ONLINE` 那种全大写小字）。
class SourceSectionLabel extends StatelessWidget {
  /// 创建标题。
  const SourceSectionLabel(this.text, {super.key});

  /// 文本。
  final String text;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return Text(
      text,
      style: TextStyle(
        color: accent.uiMutedText,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 2.2,
      ),
    );
  }
}

/// 单行输入框。
class SourceField extends StatelessWidget {
  /// 创建输入框。
  const SourceField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
    this.onSubmitted,
    this.autofocus = false,
  });

  /// 控制器。
  final TextEditingController controller;

  /// 浮动标签。
  final String label;

  /// 占位提示。
  final String hint;

  /// 是否密码。
  final bool obscure;

  /// 回车回调（搜索框用）。
  final VoidCallback? onSubmitted;

  /// 是否在进入页面时自动获得焦点。
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: obscure,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      style: TextStyle(color: accent.uiText, fontSize: 12.5),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        labelStyle: TextStyle(color: accent.uiMutedText, fontSize: 11.5),
        hintStyle: TextStyle(color: accent.uiDisabledText, fontSize: 11.5),
        filled: true,
        fillColor: accent.uiPanelFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent.uiBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent.uiBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: AppColors.neonCyan.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

/// 空状态 / 说明文字。
class SourceHint extends StatelessWidget {
  /// 创建提示。
  const SourceHint(this.text, {super.key, this.icon = Icons.info_outline});

  /// 文本。
  final String text;

  /// 图标。
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 22, color: accent.uiDisabledText),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent.uiMutedText,
                fontSize: 13,
                height: 1.7,
                shadows: <Shadow>[
                  Shadow(color: Color(0x99000000), blurRadius: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行状态（成功 / 失败配色）。
class SourceStatusLine extends StatelessWidget {
  /// 创建状态行。
  const SourceStatusLine({
    super.key,
    required this.text,
    required this.ok,
    this.busy = false,
    this.maxLines,
  });

  /// 文本。
  final String text;

  /// 是否是成功态。
  final bool ok;

  /// 是否进行中（显示转圈）。
  final bool busy;

  /// 窄屏搜索页限制状态摘要高度，避免把结果列表挤出可滚动区域。
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (busy)
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 15,
            color: ok ? accent.primary : AppColors.neonMagenta,
          ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
            style: TextStyle(
              color: ok ? accent.uiText : AppColors.neonMagenta,
              fontSize: 12,
              height: 1.5,
              shadows: const <Shadow>[
                Shadow(color: Color(0x99000000), blurRadius: 6),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 搜索结果 / 收藏里的小封面（带占位）。
class SourceCover extends StatelessWidget {
  /// 创建封面。
  const SourceCover({
    super.key,
    required this.bytes,
    this.fallbackUrl = '',
    this.size = 38,
  });

  /// 已经拿到的图片数据。
  final Uint8List? bytes;

  /// 备用（网络地址直连，拿不到数据时给 `Image.network` 用）。
  final String fallbackUrl;

  /// 边长。
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final Widget placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: accent.isLightMonochrome
            ? accent.uiPanelFill
            : Colors.white.withValues(alpha: 0.08),
      ),
      child: Icon(
        Icons.music_note_rounded,
        size: size * 0.45,
        color: accent.uiMutedText,
      ),
    );

    Widget child = placeholder;
    if (bytes != null && bytes!.isNotEmpty) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          bytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    } else if (fallbackUrl.isNotEmpty) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          fallbackUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stack,
          ) => placeholder,
        ),
      );
    }
    return SizedBox(width: size, height: size, child: child);
  }
}
