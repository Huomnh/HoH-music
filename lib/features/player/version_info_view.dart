import 'package:flutter/material.dart';

import '../../shared/constants.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';

/// 独立的版本说明和反馈入口。
class VersionInfoView extends StatelessWidget {
  const VersionInfoView({super.key});

  static const TextStyle _label = TextStyle(
    color: Color(0x8CFFFFFF),
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 2.2,
  );

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      initialSweepPhase: 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('版本说明', style: _label),
          const SizedBox(height: 8),
          const Text(
            '查看当前版本、更新说明和问题反馈入口。',
            style: TextStyle(color: AppColors.textTertiary, fontSize: 11.5),
          ),
          const SizedBox(height: 18),
          Container(
            constraints: const BoxConstraints(maxWidth: 880),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.black.withValues(alpha: 0.20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: accent.primary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'HoH music',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'v${AppConstants.version}',
                      style: TextStyle(color: accent.primary, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '当前为 Windows beta 版本。Bug、功能建议和版本更新将在 GitHub 仓库中维护。',
                  style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  AppConstants.repositoryUrl,
                  style: TextStyle(color: accent.primary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
