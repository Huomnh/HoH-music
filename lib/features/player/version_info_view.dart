import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/update_service.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';

/// 独立的版本说明和反馈入口。
class VersionInfoView extends StatefulWidget {
  const VersionInfoView({super.key});

  @override
  State<VersionInfoView> createState() => _VersionInfoViewState();
}

class _VersionInfoViewState extends State<VersionInfoView> {
  static const TextStyle _label = TextStyle(
    color: Color(0x8CFFFFFF),
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 2.2,
  );

  late Future<AppUpdate?> _updateFuture;

  @override
  void initState() {
    super.initState();
    _updateFuture = UpdateService().checkForWindowsUpdate(allowDebug: true);
  }

  Future<void> _openRepository() async {
    await launchUrl(
      Uri.parse(AppConstants.repositoryUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _checkAgain() async {
    setState(() {
      _updateFuture = UpdateService().checkForWindowsUpdate(allowDebug: true);
    });
  }

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
                  '当前为 Windows 0.1.0 稳定版。Bug、功能建议和版本更新将在 GitHub 仓库中维护。',
                  style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _openRepository,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      AppConstants.repositoryUrl,
                      style: TextStyle(
                        color: accent.primary,
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                        decorationColor: accent.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _ContributorsSection(accent: accent),
                const SizedBox(height: 16),
                _UpdateSection(future: _updateFuture, onRefresh: _checkAgain),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContributorsSection extends StatelessWidget {
  const _ContributorsSection({required this.accent});

  final AppAccent accent;

  @override
  Widget build(BuildContext context) {
    final List<String> contributors = AppConstants.contributors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '贡献名单',
          style: TextStyle(
            color: accent.primary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          contributors.isEmpty
              ? '名单待补充：感谢所有提出建设性功能建议和 Bug 反馈的用户。'
              : '${AppConstants.contributorPlatform}：${contributors.join('、')}',
          style: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: 11,
            height: 1.6,
          ),
        ),
        if (contributors.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          const Text(
            '提出建设性功能建议或 Bug 反馈的网友 ID',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

class _UpdateSection extends StatelessWidget {
  const _UpdateSection({required this.future, required this.onRefresh});

  final Future<AppUpdate?> future;
  final VoidCallback onRefresh;

  Future<void> _open(AppUpdate update) async {
    await launchUrl(
      Uri.parse(update.asset.downloadUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return FutureBuilder<AppUpdate?>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<AppUpdate?> snapshot) {
        final AppUpdate? update = snapshot.data;
        final String status =
            snapshot.connectionState == ConnectionState.waiting
            ? '正在检查 GitHub Releases…'
            : update == null
            ? '当前已是最新版本，或暂时无法连接更新服务。'
            : '发现 v${update.version}，可下载 ${update.asset.name}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '版本更新',
                  style: TextStyle(
                    color: accent.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '重新检查',
                  onPressed: snapshot.connectionState == ConnectionState.waiting
                      ? null
                      : onRefresh,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  color: accent.primary,
                  splashRadius: 16,
                ),
              ],
            ),
            Text(
              status,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
            if (update != null) ...<Widget>[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => _open(update),
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('打开下载链接'),
              ),
            ],
          ],
        );
      },
    );
  }
}
