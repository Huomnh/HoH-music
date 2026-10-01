import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/update_service.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';

/// 启动后提示可用的新版本，但不阻断播放和页面交互。
///
/// 网络失败或 GitHub 暂时不可用时不显示提示；用户点击“稍后”即可继续使用，
/// 也可以在版本说明页重新检查。安装器下载/安装由系统处理。
class OptionalUpdatePrompt extends StatefulWidget {
  const OptionalUpdatePrompt({super.key, required this.child});

  final Widget child;

  @override
  State<OptionalUpdatePrompt> createState() => _OptionalUpdatePromptState();
}

class _OptionalUpdatePromptState extends State<OptionalUpdatePrompt> {
  late final Future<AppUpdate?> _future;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _future = UpdateService().checkForWindowsUpdate();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppUpdate?>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<AppUpdate?> snapshot) {
        final AppUpdate? update = snapshot.data;
        if (update == null || _dismissed) return widget.child;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            widget.child,
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: _OptionalUpdatePanel(
                    update: update,
                    onLater: () => setState(() => _dismissed = true),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OptionalUpdatePanel extends StatelessWidget {
  const _OptionalUpdatePanel({required this.update, required this.onLater});

  final AppUpdate update;
  final VoidCallback onLater;

  Future<void> _openDownload() async {
    await launchUrl(
      Uri.parse(update.asset.downloadUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final String notes = releaseNotesToPlainText(update.notes);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
      child: Material(
        color: const Color(0xFF171B2A),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Icon(
                Icons.system_update_rounded,
                color: accent.primary,
                size: 42,
              ),
              const SizedBox(height: 12),
              const Text(
                '发现新版本',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '检测到新版本 v${update.version}，当前版本为 v${AppConstants.version}。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
              if (notes.isNotEmpty) ...<Widget>[
                const SizedBox(height: 18),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _openDownload,
                icon: const Icon(Icons.download_rounded),
                label: Text('下载 ${update.asset.name}'),
                style: FilledButton.styleFrom(
                  backgroundColor: accent.primary,
                  foregroundColor: AppAccent.safeTextOn(accent.primary),
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '下载完成后关闭本程序，运行安装包完成更新；也可以稍后在版本说明页重新检查。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 10.5,
                ),
              ),
              TextButton(onPressed: onLater, child: const Text('稍后')),
            ],
          ),
        ),
      ),
    );
  }
}
