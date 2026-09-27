/// playback_settings.dart
///
/// 播放设置页（与「外观设置」并列，同样内嵌在右侧主区）。
///
/// 提供启动行为、全局快捷键和封面来源设置。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/metadata/cover_art.dart';
import '../../platforms/windows/global_hotkey_service.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/constants.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';
import '../library/library_store.dart';

/// 播放设置页。
class PlaybackSettingsView extends ConsumerWidget {
  const PlaybackSettingsView({super.key});

  static const TextStyle _sectionLabel = TextStyle(
    color: Color(0x8CFFFFFF),
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 2.2,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final AsyncValue<StartupBehavior> behavior = ref.watch(
      startupBehaviorProvider,
    );
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      initialSweepPhase: 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('播放设置', style: _sectionLabel),
          const SizedBox(height: 8),
          const Text(
            '管理启动行为、快捷键和封面显示来源。',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),

          Expanded(
            child: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _GroupLabel('启动', color: accent.primary),
                      _StartupChoice(
                        behavior: behavior.value ?? StartupBehavior.autoLoad,
                        accent: accent,
                        onChanged: (StartupBehavior b) => ref
                            .read(startupBehaviorProvider.notifier)
                            .setBehavior(b),
                      ),

                      const SizedBox(height: 18),
                      _GroupLabel('全局快捷键', color: accent.primary),
                      const HotkeySettingsSection(),

                      const SizedBox(height: 18),
                      _GroupLabel('歌曲封面', color: accent.primary),
                      const CoverSourceSection(),

                      const SizedBox(height: 18),
                      _VersionInfoSection(accent: accent),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionInfoSection extends StatelessWidget {
  const _VersionInfoSection({required this.accent});

  final AppAccent accent;

  @override
  Widget build(BuildContext context) {
    final bool hasRepository = AppConstants.repositoryUrl.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _GroupLabel('版本说明', color: accent.primary),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.black.withValues(alpha: 0.20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.info_outline_rounded, size: 16, color: accent.primary),
                  const SizedBox(width: 8),
                  const Text(
                    'HoH music',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    'v${AppConstants.version}',
                    style: TextStyle(color: accent.primary, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '当前为 Windows beta 版本，问题反馈、功能建议和更新说明将在项目仓库中维护。',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 8),
              if (hasRepository)
                SelectableText(
                  AppConstants.repositoryUrl,
                  style: TextStyle(color: accent.primary, fontSize: 11),
                )
              else
                const Text(
                  'GitHub 仓库链接将在仓库创建后显示。',
                  style: TextStyle(color: AppColors.textTertiary, fontSize: 10.5),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 全局快捷键开关与当前按键绑定表。
class HotkeySettingsSection extends ConsumerWidget {
  const HotkeySettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final bool supported = GlobalHotkeyService.isSupported;
    final bool enabled = ref.watch(hotkeysEnabledProvider).value ?? true;
    final Set<HotkeyAction> failed = GlobalHotkeyService.instance.failedActions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '启用全局快捷键',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    supported ? '应用在后台时也能控制播放；被别的软件占用时该键会失效' : '当前平台不支持',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: enabled && supported,
              onChanged: supported
                  ? (bool v) =>
                        ref.read(hotkeysEnabledProvider.notifier).setEnabled(v)
                  : null,
              activeThumbColor: accent.primary,
              activeTrackColor: accent.primary.withValues(alpha: 0.35),
              inactiveThumbColor: AppColors.textTertiary,
              inactiveTrackColor: AppColors.divider,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final HotkeySpec spec in kHotkeySpecs)
              _HotkeyChip(
                spec: spec,
                accent: accent,
                dimmed: !enabled || !supported,
                failed: failed.contains(spec.action),
              ),
          ],
        ),
      ],
    );
  }
}

/// 一条快捷键的展示。
class _HotkeyChip extends StatelessWidget {
  const _HotkeyChip({
    required this.spec,
    required this.accent,
    required this.dimmed,
    required this.failed,
  });

  final HotkeySpec spec;
  final AppAccent accent;
  final bool dimmed;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final Color borderColor = failed
        ? const Color(0xFFFF6B6B).withValues(alpha: 0.55)
        : Colors.white.withValues(alpha: 0.10);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.black.withValues(alpha: 0.22),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Opacity(
            opacity: dimmed ? 0.45 : 1,
            child: Text(
              spec.label,
              style: const TextStyle(color: Colors.white, fontSize: 11.5),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: Colors.black.withValues(alpha: 0.35),
              border: Border.all(
                color: dimmed
                    ? Colors.white.withValues(alpha: 0.10)
                    : accent.primary.withValues(alpha: 0.45),
              ),
            ),
            child: Text(
              spec.keysLabel,
              style: TextStyle(
                fontSize: 10,
                color: dimmed ? AppColors.textTertiary : accent.primary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (failed) ...<Widget>[
            const SizedBox(width: 6),
            const Tooltip(
              message: '注册失败：多半被别的软件占用了',
              child: Icon(
                Icons.error_outline,
                size: 12,
                color: Color(0xFFFF8A8A),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 歌曲封面来源：内嵌 / 网络刮削 / 自动。
class CoverSourceSection extends ConsumerWidget {
  const CoverSourceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final CoverSource source =
        ref.watch(coverSourceProvider).value ?? CoverSource.auto;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final CoverSource option in CoverSource.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _ChoiceCard(
                    title: option.label,
                    description: option.description,
                    selected: option == source,
                    accent: accent,
                    onTap: () {
                      ref.read(coverSourceProvider.notifier).setSource(option);
                      // 换来源后旧缓存作废，强制重取
                      CoverArtService.instance.clearCache();
                    },
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          CoverArtService.needsNetwork(source)
              ? '网络刮削使用 iTunes Search API；'
                    '没联网时自动退回占位封面，不影响播放。'
              : '只读音频文件里的内嵌封面，完全离线。',
          style: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: 10.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        const _ScraperSourceRow(),
      ],
    );
  }
}

/// 刮削源列表。
///
/// 0.0.34：按用户要求**去掉所有 lx-music（自定义音源）相关的内容** ——
/// 那条线已整体下线，这里不再提"未接入"。
class _ScraperSourceRow extends StatelessWidget {
  const _ScraperSourceRow();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text(
              '刮削源',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: Colors.black.withValues(alpha: 0.25),
                border: Border.all(
                  color: AppColors.neonCyan.withValues(alpha: 0.5),
                ),
              ),
              child: const Text(
                'iTunes Search API',
                style: TextStyle(color: AppColors.neonCyan, fontSize: 10.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '本地曲目优先匹配已启用的自定义音源 pic，封面缺失时回退到 iTunes；'
          '匹配不严宁可不显示，也不会挂错图。',
          style: TextStyle(
            color: AppColors.textTertiary,
            fontSize: 10.5,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// 启动行为二选一（0.0.23：去掉了「启动后不播放」）。
///
/// `StartupBehavior.idle` 仍然留在枚举里 —— 老盘里可能存着它，
/// `StartupBehaviorController` 会把这种记录迁移成 `autoLoad`；
/// 这里只是不再给用户提供这个选项（用户明确要求去掉）。
class _StartupChoice extends StatelessWidget {
  const _StartupChoice({
    required this.behavior,
    required this.accent,
    required this.onChanged,
  });

  /// 界面上可选的启动行为。
  static const List<StartupBehavior> choices = <StartupBehavior>[
    StartupBehavior.autoLoad,
    StartupBehavior.autoPlay,
  ];

  final StartupBehavior behavior;
  final AppAccent accent;
  final ValueChanged<StartupBehavior> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (final StartupBehavior b in choices)
          SizedBox(
            width: 236,
            child: _ChoiceCard(
              title: b.label,
              description: b.description,
              selected: b == behavior,
              accent: accent,
              onTap: () => onChanged(b),
            ),
          ),
      ],
    );
  }
}

/// 可选项卡片。
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.title,
    required this.description,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String title;
  final String description;
  final bool selected;
  final AppAccent accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: selected
                ? accent.primary.withValues(alpha: 0.14)
                : Colors.black.withValues(alpha: 0.22),
            border: Border.all(
              color: selected
                  ? accent.primary.withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.10),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 16,
                color: selected ? accent.primary : const Color(0x66FFFFFF),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 10.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分组小标题（颜色跟随强调色）。
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.title, {required this.color});

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
