import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// media_kit 也导出 Track，与本项目的 Track 同名，隐藏之
// media_kit 也导出 Playlist / Track，与本项目的同名，隐藏之
import 'package:media_kit/media_kit.dart' hide Track, Playlist;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hoh_music/app.dart';
import 'package:hoh_music/core/audio/player_engine.dart';
import 'package:hoh_music/core/audio/player_providers.dart';
import 'package:hoh_music/core/metadata/cover_art.dart';
import 'package:hoh_music/features/library/library_store.dart';
import 'package:hoh_music/features/library/playlists.dart';
import 'package:hoh_music/features/player/appearance_settings.dart';
import 'package:hoh_music/features/player/cover_stage.dart';
import 'package:hoh_music/features/player/cover_style.dart';
import 'package:hoh_music/features/player/lyrics/lyrics_parser.dart';
import 'package:hoh_music/features/player/lyrics/lyrics_scene.dart';
import 'package:hoh_music/features/player/lyrics/lyrics_style.dart';
import 'package:hoh_music/features/player/lyrics/lyrics_view.dart';
import 'package:hoh_music/features/player/playback_settings.dart';
import 'package:hoh_music/features/player/player_page.dart';
import 'package:hoh_music/platforms/windows/debug_autoexit.dart';
import 'package:hoh_music/platforms/windows/global_hotkey_service.dart';
import 'package:hoh_music/platforms/windows/lyrics_overlay.dart';
import 'package:hoh_music/platforms/windows/smtc_service.dart';
import 'package:hoh_music/shared/theme/app_accent.dart';
import 'package:hoh_music/shared/theme/app_background.dart';
import 'package:hoh_music/shared/theme/performance_tier.dart';
import 'package:hoh_music/shared/widgets/widget_kit/widget_kit.dart';

/// 测试视口：模拟 1280×800 的 Windows 桌面窗口。
///
/// 默认的 800×600 是手机竖屏尺寸，会把三栏布局压扁并触发一堆溢出告警，
/// 那些告警在真实桌面上并不会出现，反而掩盖真正的布局问题。
void _useDesktopViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(2560, 1600); // 逻辑尺寸 1280×800
}

/// 挂载应用。
///
/// ⚠️ 不能用 `pumpAndSettle`：玻璃面板的旋转高光是 `repeat()` 的无限动画，
/// `pumpAndSettle` 会一直等它停下来，最终超时。统一用固定时长的 `pump`。
Future<void> _pumpApp(WidgetTester tester) async {
  _useDesktopViewport(tester);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const ProviderScope(child: HoHMusicApp()));
  await tester.pump(const Duration(milliseconds: 100));
}

/// 推进动画若干帧，替代 `pumpAndSettle`。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() {
    // 组件测试下 Flutter 会尝试请求图标字体，这里统一拦截，避免噪音日志。
    HttpOverrides.global = _NoNetworkHttpOverrides();

    // PlayerController 会读取 media_kit 的状态快照，
    // 未初始化时 media_kit 会直接抛异常，所以测试里也要初始化一次。
    // 这里只做 Dart 侧初始化，不会真的去加载解码后端。
    try {
      MediaKit.ensureInitialized();
    } catch (_) {
      // 无原生库的环境（如纯 Dart 测试）忽略即可，后续用例会自行跳过
    }
  });

  setUp(() {
    // 背景 / 音乐库 / 启动行为都会读写 shared_preferences。
    // 必须**每个用例重置一次**：否则前一个用例选过的背景会漏到下一个用例里
    // （真实踩到过：设置用例把背景改成纯色底，后面的"强调色=默认"断言因此失败）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDownAll(() {
    HttpOverrides.global = null;
  });

  testWidgets('播放页骨架可以正常构建', (WidgetTester tester) async {
    await _pumpApp(tester);

    // 标题栏
    expect(find.text('HoH music'), findsOneWidget);
    // 队列为空时应显示空状态而不是假数据。
    // 默认摄影机词幕只在左侧控制台显示空播放状态。
    expect(find.text('未在播放'), findsOneWidget);

    // 控制台在侧边栏顶部：黑胶 + 走带按键都在
    expect(find.byType(VinylRecord), findsOneWidget);
    expect(find.byTooltip('上一首'), findsOneWidget);
    expect(find.byTooltip('下一首'), findsOneWidget);
    expect(find.byTooltip('播放模式：顺序播放（点击切换）'), findsOneWidget);
  });

  test('从所有歌曲移除只持久化隐藏 ID，可撤销且不操作磁盘文件', () async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(hiddenLibraryTracksProvider.future);

    const String id = r'E:\Music\song.flac';
    await container.read(hiddenLibraryTracksProvider.notifier).hide(id);
    expect(container.read(hiddenLibraryTracksProvider).value, contains(id));
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        'library.hiddenTrackIds',
      ),
      <String>[id],
    );

    await container.read(hiddenLibraryTracksProvider.notifier).restore(id);
    expect(
      container.read(hiddenLibraryTracksProvider).value,
      isNot(contains(id)),
    );
  });

  testWidgets('侧边栏包含音乐库 / 歌单 / 来源三组导航', (WidgetTester tester) async {
    await _pumpApp(tester);

    expect(find.text('音乐库'), findsOneWidget);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('WebDAV'), findsOneWidget);
    // 0.0.21：本地音乐入口从侧边栏撤掉了（控制台占了这块位置），
    // 现在只在「播放设置 → 音乐库」里
    expect(find.text('打开文件夹'), findsNothing);
    expect(find.text('添加单曲'), findsNothing);
    // 设置入口挪到了侧边栏（「来源」下面），不再是标题栏弹窗
    expect(find.text('外观设置'), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);
  });

  testWidgets('队列抽屉默认收起', (WidgetTester tester) async {
    await _pumpApp(tester);

    // 「播放队列」出现两处：控制栏按钮文案 + 抽屉面板标题
    // （抽屉收起时面板只是滑到屏幕外，仍在 widget 树上）
    expect(find.text('播放队列'), findsNWidgets(2));
    // 收起状态下按钮文案不是「收起队列」
    expect(find.text('收起队列'), findsNothing);
  });

  testWidgets('点击队列按钮可以展开，点空白处收起', (WidgetTester tester) async {
    await _pumpApp(tester);

    // 展开：按钮文案变成「收起队列」
    await tester.tap(find.text('播放队列').first);
    await _settle(tester);

    expect(find.text('收起队列'), findsOneWidget);
    expect(find.text('0 首'), findsOneWidget);
    // 空队列提示
    expect(find.text('队列是空的'), findsOneWidget);

    // 收起：点抽屉外的空白 —— 抽屉是**模态**的，遮罩盖住整个主界面
    // （侧边栏控制台也在下面），所以点控制台上的「收起队列」会先被遮罩吃掉
    await tester.tapAt(const Offset(500, 400));
    await _settle(tester);

    expect(find.text('收起队列'), findsNothing);
    expect(find.text('播放队列'), findsNWidgets(2));
  });

  testWidgets('设置页从侧边栏进入，内容显示在右侧主区（不是弹窗）', (WidgetTester tester) async {
    await _pumpApp(tester);

    // 入口在侧边栏；标题栏的齿轮是同一页的快捷方式
    expect(find.text('外观设置'), findsOneWidget);
    expect(find.byTooltip('外观设置'), findsOneWidget);

    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    // 右侧主区换成了设置页：播放页的曲目信息不再显示，
    // 但左侧控制台是常驻的，它那句「未在播放」还在（0.0.21）
    expect(find.text('未在播放'), findsOneWidget);
    expect(find.byTooltip('返回播放页'), findsOneWidget);

    // 背景组（0.0.11 新增）
    expect(find.text('背景'), findsOneWidget);
    expect(find.text('自定义图片'), findsOneWidget);

    // 0.0.8 精简后**当前确实存在**的项
    expect(find.text('模糊与通透'), findsOneWidget);
    expect(find.text('边框高光'), findsOneWidget);
    expect(find.text('模糊强度'), findsOneWidget);
    expect(find.text('高光强度'), findsOneWidget);
    expect(find.text('玻璃通透度'), findsOneWidget);
    expect(find.text('玻璃效果'), findsOneWidget);
    expect(find.text('边框高光流动'), findsOneWidget);
    expect(find.text('界面动画'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
    // 0.0.23：低配显卡模式去掉（档位本来就是自动判定的，手开关多余）
    expect(find.text('低配显卡模式'), findsNothing);
    // 已移除的项不应再出现
    expect(find.text('高光流动速度'), findsNothing);
    expect(find.text('磨砂噪点'), findsNothing);
    expect(find.text('背景粒子'), findsNothing);

    // 点左侧导航切回播放页
    await tester.tap(find.text('未在播放').first);
    await _settle(tester);
    expect(find.text('未在播放'), findsOneWidget);
  });

  testWidgets('内置背景包含液态流光，自定义图片可选中', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    // 液态流光用于主背景与缩略图。
    expect(find.byType(LiquidBloomScene), findsAtLeastNWidgets(2));

    for (final String label in <String>['液态流光', '自定义图片']) {
      expect(find.text(label), findsOneWidget, reason: '缺少背景缩略图：$label');
    }
  });

  testWidgets('自定义背景的缩略图不会跟着其它选中项一起变（0.0.12 修的 bug）', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSettingsView)),
    );
    // 假装用户选了一张自定义图片（测试里不真读文件：路径不存在时
    // errorBuilder 会退回场景，但**缩略图传下去的 selection 仍然会被断言**）
    container.read(backgroundProvider.notifier).setCustomImage('E:/tmp/bg.png');
    await _settle(tester);

    // 再点液态流光：自定义图片缩略图仍保持其自身 selection。
    await tester.tap(find.text('液态流光'));
    await _settle(tester);

    final List<BackgroundLayer> layers = tester
        .widgetList<BackgroundLayer>(find.byType(BackgroundLayer))
        .toList();
    final bool customTileStillCustom = layers.any(
      (BackgroundLayer l) =>
          l.selection.kind == BackgroundKind.custom &&
          l.selection.customImagePath == 'E:/tmp/bg.png',
    );

    expect(
      customTileStillCustom,
      isTrue,
      reason: '自定义那一格必须始终渲染那张图片，不能跟着当前选中项变',
    );
    expect(
      layers.any(
        (BackgroundLayer l) =>
            l.selection.kind == BackgroundKind.custom &&
            l.selection.customImagePath == null,
      ),
      isFalse,
      reason: '自定义缩略图不该拿到"当前选中的场景"',
    );
  });

  testWidgets('音乐库里的编码路径会被修回真实路径（0.0.14 修的 bug）', (WidgetTester tester) async {
    // 造一个带空格与中文的真实文件，模拟用户选中的单曲
    final Directory dir = Directory.systemTemp.createTempSync(
      'hoh_library_test',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final String realPath = '${dir.path}\\半句再见 - 孙燕姿.flac';
    File(realPath).writeAsStringSync('demo');

    // file_picker 13 的 Windows 实现返回的是 Uri.path（百分号编码 + 前导斜杠），
    // 这里用同一个 API 生成"坏路径"，保证复现的是真实故障形态
    final String brokenPath = File(realPath).uri.path;
    expect(brokenPath, contains('%'), reason: '这个路径必须是编码过的才叫复现');

    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.library.folders': jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'path': brokenPath,
          'addedAt': '2026-01-01T00:00:00.000',
          'kind': 'file',
          'trackCount': 1,
        },
      ]),
    });

    await _pumpApp(tester);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    final List<LibraryEntry> entries = await container.read(
      libraryProvider.future,
    );

    expect(entries, hasLength(1));
    expect(
      entries.single.path,
      realPath,
      reason: '加载时应把 %E5%8D%8A... 这类编码路径解码成真实路径',
    );
    expect(entries.single.exists, isTrue);
  });

  testWidgets('播放模式一个按钮四挡循环，且不会立刻换歌（0.0.16）', (WidgetTester tester) async {
    await _pumpApp(tester);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    final PlayerController controller = container.read(
      playerControllerProvider.notifier,
    );

    // 默认顺序播放
    expect(
      container.read(playerControllerProvider).mode,
      PlaybackMode.sequential,
    );

    // 顺序 → 列表循环 → 单曲循环 → 随机 → 顺序
    controller.cyclePlaybackMode();
    await _settle(tester);
    expect(
      container.read(playerControllerProvider).mode,
      PlaybackMode.repeatAll,
    );
    controller.cyclePlaybackMode();
    await _settle(tester);
    expect(
      container.read(playerControllerProvider).mode,
      PlaybackMode.repeatOne,
    );
    controller.cyclePlaybackMode();
    await _settle(tester);
    expect(container.read(playerControllerProvider).mode, PlaybackMode.shuffle);
    controller.cyclePlaybackMode();
    await _settle(tester);
    expect(
      container.read(playerControllerProvider).mode,
      PlaybackMode.sequential,
    );

    // 只有一个模式按钮（不再有独立的随机 + 循环两个）
    expect(find.byTooltip('播放模式：顺序播放（点击切换）'), findsOneWidget);

    // 模式会写盘
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('playback.mode'), PlaybackMode.sequential.name);
  });

  testWidgets('歌词面板：没有曲目时显示占位而不是假歌词（0.0.16）', (WidgetTester tester) async {
    await _pumpApp(tester);

    expect(find.byType(LyricsScene), findsOneWidget);
    expect(find.text('暂无歌词'), findsOneWidget);
    // 以前这里是写死的假歌词，不该再出现
    expect(find.text('沿着霓虹的海岸线行驶'), findsNothing);
    // 左上角那行「正在播放」小标题已经去掉
    // 0.0.40：侧边栏那个导航项也去掉了（正在播放入口改成"点控制台"）
    expect(find.text('正在播放'), findsNothing);
    // 取而代之：侧边栏第一位是「在线搜索」
    expect(find.text('在线搜索'), findsOneWidget);
  });

  testWidgets('歌曲信息里有音质格式信息（0.0.16）', (WidgetTester tester) async {
    await _pumpApp(tester);
    // 没在播放时只显示"未在播放"，没有音质徽标
    expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    final Track track = Track(
      id: r'E:\music\孙燕姿 - 半句再见.flac',
      uri: 'file:///E:/music/x.flac',
      title: '半句再见',
      artist: '孙燕姿',
      album: '跳舞的梵谷',
      sampleRate: 44100,
      bitrate: 1000000,
      fileSize: 34000000,
    );
    expect(
      track.qualityLabel,
      'FLAC · 44.1 kHz · 1000 kbps · 32.4 MB',
      reason: 'bitrate=1000 属于"已经是 kbps"那一档',
    );

    // 归一：WAV / AIFF 给的是 byte/s（88200 = 44100 × 2），要 ×8 才是 bit
    final Track wav = Track(
      id: r'E:\music\x.wav',
      uri: 'file:///E:/music/x.wav',
      title: 'x',
      artist: 'y',
      album: 'z',
      sampleRate: 44100,
      bitrate: 88200,
      fileSize: 2646044,
    );
    expect(wav.qualityLabel, 'WAV · 44.1 kHz · 706 kbps · 2.5 MB');

    // 归一：FLAC 给的是 bit/s（705600）
    final Track flac = Track(
      id: r'E:\music\y.flac',
      uri: 'file:///E:/music/y.flac',
      title: 'x',
      artist: 'y',
      album: 'z',
      sampleRate: 44100,
      bitrate: 705600,
    );
    expect(flac.qualityLabel, 'FLAC · 44.1 kHz · 706 kbps');

    // 归一：MP3 给的就是 kbps（320）
    final Track mp3 = Track(
      id: r'E:\music\z.mp3',
      uri: 'file:///E:/music/z.mp3',
      title: 'x',
      artist: 'y',
      album: 'z',
      sampleRate: 44100,
      bitrate: 320,
    );
    expect(mp3.qualityLabel, 'MP3 · 44.1 kHz · 320 kbps');

    expect(container, isNotNull); // 保持容器引用，避免被当成未使用
  });

  testWidgets('外观设置里有歌词自定义，改了立刻生效并写盘（0.0.17）', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    expect(find.text('歌词'), findsWidgets);
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('行距'), findsOneWidget);
    expect(find.text('歌词自动滚动'), findsOneWidget);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSettingsView)),
    );
    final LyricsStyleController controller = container.read(
      lyricsStyleProvider.notifier,
    );

    // 默认字号比 0.0.16 的 14 大（用户反馈字体太小）
    expect(
      container.read(lyricsStyleProvider).value?.fontSize,
      greaterThan(14),
    );

    await controller.setFontSize(26);
    await controller.setSpacing(LyricLineSpacing.loose);
    await controller.setAutoScroll(false);
    await _settle(tester);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('lyrics.fontSize'), 26);
    expect(prefs.getString('lyrics.spacing'), LyricLineSpacing.loose.name);
    expect(prefs.getBool('lyrics.autoScroll'), isFalse);

    // 行高必须随字号与行距算出来（滚动定位靠它）
    final LyricsStyle style = container.read(lyricsStyleProvider).value!;
    expect(style.activeFontSize, closeTo(26 * 1.25, 0.01));
    expect(style.lineExtent, closeTo(style.activeFontSize * 2.4, 0.01));
  });

  testWidgets('播放页：方形封面留在主区，黑胶在侧边栏控制台上（0.0.21 ~ 0.0.22）', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);

    // 默认摄影机词幕不渲染专辑封面；滚动列表布局会显示封面与信息栏。
    expect(find.byType(LyricsScene), findsOneWidget);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    await container
        .read(lyricsStyleProvider.notifier)
        .setLayout(LyricsLayoutMode.scrollingList);
    await tester.pump();
    expect(find.byType(CoverStage), findsOneWidget);
    // 黑胶在侧边栏顶部的控制台里（0.0.22 从 76 收到 60，用户嫌整体太大）
    expect(find.byType(VinylRecord), findsOneWidget);
    final VinylRecord disc = tester.widget<VinylRecord>(
      find.byType(VinylRecord),
    );
    expect(disc.size, 60);

    // 转速放慢了：1.8 秒一圈在真机大小下像加载动画，用户嫌快（0.0.21）
    expect(VinylRecord.secondsPerTurn, greaterThanOrEqualTo(5.0));

    // 0.0.22：模式按钮挪到曲名那一行（黑胶所在 Row 的右端），
    // 走带按键（上/下首 + 播放）单独居中一行
    expect(find.byTooltip('播放模式：顺序播放（点击切换）'), findsOneWidget);
    expect(find.byTooltip('上一首'), findsOneWidget);
    expect(find.byTooltip('下一首'), findsOneWidget);

    // 0.0.41：播放模式按钮改成和走带按键同一行（「下一首」右边），
    //          喜欢按钮在「上一首」左边 —— 断言"它们共用一个 Row"。
    final Element transportRow = find
        .ancestor(of: find.byTooltip('上一首'), matching: find.byType(Row))
        .evaluate()
        .first;
    expect(
      find.descendant(
        of: find.byElementPredicate((Element e) => e == transportRow),
        matching: find.byTooltip('播放模式：顺序播放（点击切换）'),
      ),
      findsOneWidget,
      reason: '播放模式按钮应该在走带那一行的「下一首」右边',
    );
    expect(
      find.descendant(
        of: find.byElementPredicate((Element e) => e == transportRow),
        matching: find.byTooltip('下一首'),
      ),
      findsOneWidget,
    );
    // 黑胶仍在上面那一行（不和走带按键挤在一起）
    expect(
      find.descendant(
        of: find.byElementPredicate((Element e) => e == transportRow),
        matching: find.byType(VinylRecord),
      ),
      findsNothing,
      reason: '黑胶不该在走带那一行',
    );
  });

  testWidgets('黑胶旋转开关可设置并写盘（0.0.20）', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    expect(find.text('封面黑胶'), findsOneWidget);
    expect(find.text('黑胶旋转'), findsOneWidget);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSettingsView)),
    );
    final CoverStageStyleController controller = container.read(
      coverStageStyleProvider.notifier,
    );

    // 默认开启旋转
    expect(container.read(coverStageStyleProvider).value?.spin, isTrue);

    await controller.setSpin(false);
    await _settle(tester);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('cover.spin'), isFalse);
  });

  test('封面匹配：歌名 + 艺术家都要像才算数', () {
    // 完全一致
    expect(CoverArtService.similarity('半句再见', '半句再见'), 1.0);
    // 搜索结果的括号后缀要被忽略：(Live) 版仍算同一个名字
    expect(CoverArtService.similarity('半句再见', '半句再见 (Live)'), greaterThan(0.7));
    // 翻唱现场版：歌名一样但艺术家不同
    // 0.0.16 只要求综合分 ≥0.55，恰好放行了这种"歌名全中、艺术家全不中"的错配；
    // 0.0.17 要求歌名与艺术家**都**过线，所以它必须被拒
    final double titleScore = CoverArtService.similarity('半句再见', '半句再见');
    final double artistScore = CoverArtService.similarity('孙燕姿', '某选手');
    final double combined = titleScore * 0.55 + artistScore * 0.45;
    expect(combined, greaterThan(0.5));
    expect(
      titleScore >= 0.70 && artistScore >= 0.45,
      isFalse,
      reason: '歌名全中但艺术家不像 → 不该被接受（这正是用户看到的"封面不符"）',
    );
    // 完全不相关的名字分数很低
    expect(CoverArtService.similarity('半句再见', 'Rice Field'), lessThan(0.3));
    // 大小写、空格、标点都不影响
    expect(CoverArtService.similarity('Jay Chou', 'jay  chou!'), 1.0);
  });

  testWidgets('播放设置页包含全局快捷键区（0.0.15）', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('播放设置'));
    await _settle(tester);
    await _settle(tester);

    expect(find.text('全局快捷键'), findsOneWidget);
    expect(find.text('启用全局快捷键'), findsOneWidget);
    // 绑定表（只读展示）
    for (final HotkeySpec spec in kHotkeySpecs) {
      expect(find.text(spec.label), findsOneWidget);
      expect(find.text(spec.keysLabel), findsOneWidget);
    }
  });

  testWidgets('播放设置页：扫描记录与启动行为都在（0.0.12）', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('播放设置'));
    // 扫描记录是异步读盘的（AsyncNotifier），多给一帧让它落地
    await _settle(tester);
    await _settle(tester);

    // 播放页的曲目信息不再显示（左侧控制台是常驻的，所以还剩一处「未在播放」）
    expect(find.text('未在播放'), findsOneWidget);

    // 启动行为二选一（0.0.21 加了默认的「自动载入」；
    // 0.0.23 按用户要求去掉了「启动后不播放」）
    expect(find.text('启动'), findsOneWidget);
    expect(find.text('启动后自动载入'), findsOneWidget);
    expect(find.text('启动后自动播放'), findsOneWidget);
    expect(find.text('启动后不播放'), findsNothing);

    // 0.0.55：**音乐库那套 UI 已从播放设置搬到「来源 → 音源管理」**，
    //         所以这里不再断言它的存在，改为去来源页验证。
    await tester.tap(find.text('音源管理'));
    await _settle(tester);
    expect(find.text('添加文件夹'), findsOneWidget);
    expect(find.text('添加单曲'), findsOneWidget);
    expect(find.text('载入音乐库'), findsOneWidget);
    expect(find.text('清空本地索引'), findsOneWidget);
    expect(find.text('清空在线播放记录'), findsOneWidget);
    expect(find.textContaining('音乐库：还没有添加'), findsOneWidget);

    // 切回播放设置（它现在只剩启动 / 快捷键 / 封面 / 音源与刮削来源）
    await tester.tap(find.text('播放设置'));
    await _settle(tester);
    expect(find.text('启动后自动载入'), findsOneWidget);

    // 音乐库里可以同时有「文件夹」和「单曲」两种记录（0.0.13）
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(PlaybackSettingsView)),
    );
    await container
        .read(libraryProvider.notifier)
        .addFile(r'E:\music\single-track.flac');
    await container.read(libraryProvider.notifier).addFolder(r'E:\music\album');
    await _settle(tester);

    // 列表在「来源 → 音源管理」页（0.0.55 搬过去的），切过去看
    await tester.tap(find.text('音源管理'));
    await _settle(tester);
    expect(find.textContaining('single-track.flac'), findsOneWidget);
    expect(find.textContaining('album'), findsOneWidget);
    expect(find.textContaining('1 个文件夹 · 1 首单曲'), findsOneWidget);

    // 回播放设置继续验证启动行为（设置项还在那边）
    await tester.tap(find.text('播放设置'));
    await _settle(tester);

    // 默认是「自动载入」（0.0.21 按用户要求改的默认值）
    expect(
      container.read(startupBehaviorProvider).value,
      StartupBehavior.autoLoad,
    );

    // 切「启动后自动播放」后立即反映在界面上（同时写进 prefs）
    await tester.tap(find.text('启动后自动播放'));
    await _settle(tester);
    expect(
      container.read(startupBehaviorProvider).value,
      StartupBehavior.autoPlay,
    );

    // 点左侧导航切回播放页
    await tester.tap(find.text('未在播放').first);
    await _settle(tester);
    expect(find.text('未在播放'), findsOneWidget);
  });

  testWidgets('启动行为默认自动载入，旧记录只迁移一次（0.0.21）', (WidgetTester tester) async {
    // 旧版本（两个选项那会儿）留下的记录
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.library.startup': 'idle',
    });

    await _pumpApp(tester);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    expect(
      await container.read(startupBehaviorProvider.future),
      StartupBehavior.autoLoad,
      reason: '0.0.21 把默认值改成「自动载入」，旧的 idle 记录要跟着迁移',
    );

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('library.startup'), StartupBehavior.autoLoad.name);
    expect(prefs.getBool('library.startup.migratedAutoLoad'), isTrue);

    // 迁移只做一次：用户之后明确选「启动后不播放」不会再被改回去
    await container
        .read(startupBehaviorProvider.notifier)
        .setBehavior(StartupBehavior.idle);
    final ProviderContainer again = ProviderContainer();
    addTearDown(again.dispose);
    expect(
      await again.read(startupBehaviorProvider.future),
      StartupBehavior.idle,
    );
  });

  test('--exit-after 参数解析（0.0.21，截图脚本用来自退）', () {
    expect(resolveDebugAutoExitSeconds(const <String>['--exit-after=22']), 22);
    // 非法/无意义的取值一律当作"没开这个功能"，避免脚本手滑传错就退不掉
    expect(
      resolveDebugAutoExitSeconds(const <String>['--exit-after=abc']),
      isNull,
    );
    expect(
      resolveDebugAutoExitSeconds(const <String>['--exit-after=0']),
      isNull,
    );
    expect(
      resolveDebugAutoExitSeconds(const <String>['--exit-after=-3']),
      isNull,
    );
    // 普通音频路径参数不能被误当成开关
    expect(
      resolveDebugAutoExitSeconds(const <String>[r'E:\music\a.mp3']),
      isNull,
    );
  });

  testWidgets('外观设置：切换玻璃开关后滚动位置不会弹回顶端（0.0.23）', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    final Finder scroll = find.descendant(
      of: find.byType(AppearanceSettingsView),
      matching: find.byType(Scrollable),
    );
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSettingsView)),
    );

    // 先真的滚下去，否则这个用例证明不了什么
    await tester.drag(scroll, const Offset(0, -240));
    await _settle(tester);
    final double before = tester.state<ScrollableState>(scroll).position.pixels;
    expect(before, greaterThan(50), reason: '得先滚下去才有得比');

    // ① 开「边框高光流动」：面板里会多出一层高光 Stack
    container.read(glassOverridesProvider.notifier).setSweep(true);
    await _settle(tester);
    expect(
      tester.state<ScrollableState>(scroll).position.pixels,
      closeTo(before, 0.5),
      reason: '高光层的出现不能把内容整棵重建（会把滚动位置丢掉）',
    );

    // ② 关「玻璃效果」：BackdropFilter 会换成纯色层，同样是结构变化
    container.read(glassOverridesProvider.notifier).setBlurSigma(0);
    await _settle(tester);
    expect(
      tester.state<ScrollableState>(scroll).position.pixels,
      closeTo(before, 0.5),
      reason: '模糊层换实现也不能重建内容',
    );

    // ③ 开回模糊 + 关动画，同样不该影响
    container.read(glassOverridesProvider.notifier).setBlurSigma(16);
    container.read(glassOverridesProvider.notifier).setAnimations(false);
    await _settle(tester);
    expect(
      tester.state<ScrollableState>(scroll).position.pixels,
      closeTo(before, 0.5),
    );
  });

  testWidgets('SMTC 宿主在测试环境里不接原生，也不挡住界面（0.0.24）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SmtcHost(child: Scaffold(body: Text('SMTC 包装后仍可渲染'))),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('SMTC 包装后仍可渲染'), findsOneWidget);
    // FLUTTER_TEST 环境下必须早退：真去起 Rust 运行时会让整套测试挂掉
    expect(SmtcService.instance.isReady, isFalse);
  });

  testWidgets('桌面歌词浮层：开关可设置并写盘，测试环境不碰原生（0.0.25）', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    expect(find.text('桌面歌词'), findsOneWidget);
    // 测试环境（FLUTTER_TEST）里绝不碰 Win32：宿主必须早退，否则整套测试会挂
    expect(LyricsOverlayHost.isSupported, isFalse);
    expect(LyricsOverlay.instance.isVisible, isFalse);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSettingsView)),
    );
    final LyricsStyleController controller = container.read(
      lyricsStyleProvider.notifier,
    );

    // 当前产品默认开启桌面歌词，但测试环境不会触碰原生窗口。
    expect(container.read(lyricsStyleProvider).value?.desktopOverlay, isTrue);

    await controller.setDesktopOverlay(true);
    await _settle(tester);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lyrics.desktopOverlay'), isTrue);
  });

  test('currentLyricLineProvider：只跟着行号变化（0.0.25）', () async {
    final Lyrics lyrics = Lyrics.parse(
      '[00:00.00]第一行\n[00:10.00]第二行\n[00:20.00]第三行',
    );
    // ⚠️ riverpod 3 没有导出 Override 类型，所以这里只能靠类型推断写列表
    final ProviderContainer container = ProviderContainer(
      overrides: [
        currentLyricsProvider.overrideWith((Ref ref) async => lyrics),
      ],
    );
    addTearDown(container.dispose);

    // 位置 provider 在测试里没引擎 → 位置为 0，取第一行
    await container.read(currentLyricsProvider.future);
    expect(container.read(currentLyricIndexProvider), 0);
    expect(container.read(currentLyricLineProvider), '第一行');
  });

  testWidgets('曲库页面：侧边栏能切到「所有歌曲」和「我的喜欢」（0.0.27）', (WidgetTester tester) async {
    await _pumpApp(tester);

    // 切到「所有歌曲」：侧栏项 + 页面标题各一处（不依赖库里有几首歌 ——
    // PlayerEngine 是单例，别的用例可能已经在队列里留了曲目）
    await tester.tap(find.text('所有歌曲'));
    await _settle(tester);
    expect(find.text('所有歌曲'), findsNWidgets(2));

    // 歌单组里的「我喜欢的音乐」是真的读用户歌单（内建收藏）。
    // 歌单是异步读盘的（AsyncNotifier），多给一帧让它落地
    await _settle(tester);
    await tester.tap(find.text('我喜欢的音乐').last);
    await _settle(tester);
    expect(find.text('我喜欢的音乐'), findsNWidgets(2));

    // 切回播放页
    await tester.tap(find.text('未在播放').first);
    await _settle(tester);
    expect(find.text('未在播放'), findsOneWidget);
  });

  test('歌单：新建 / 加歌 / 收藏 / 移除都落盘（0.0.27）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    final PlaylistsController controller = container.read(
      playlistsProvider.notifier,
    );
    await container.read(playlistsProvider.future);

    // 「我的喜欢」内建存在且排第一
    final List<Playlist> initial = container.read(playlistsProvider).value!;
    expect(initial.first.isFavorites, isTrue);
    expect(initial.first.id, favoritesId);

    final Playlist pl = await controller.create('夜间驾驶');
    await controller.addTrack(pl.id, 'a.flac');
    await controller.addTrack(pl.id, 'a.flac'); // 重复加要忽略
    expect(controller.byId(pl.id)!.trackIds, <String>['a.flac']);

    // 收藏 / 取消收藏
    expect(await controller.toggleFavorite('b.flac'), isTrue);
    expect(container.read(isFavoriteProvider('b.flac')), isTrue);
    expect(await controller.toggleFavorite('b.flac'), isFalse);
    expect(container.read(isFavoriteProvider('b.flac')), isFalse);

    // 落盘
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('library.playlists'), contains('夜间驾驶'));
  });

  testWidgets('主题强调色跟随背景（0.0.12）', (WidgetTester tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('外观设置'));
    await _settle(tester);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSettingsView)),
    );
    // 默认背景是液态流光 → 默认那套强调色
    expect(
      container.read(accentProvider).primary,
      AppAccent.forKind(BackgroundKind.liquidBloom).primary,
    );

    // 换成液态流光 → 强调色变成液态流光那套
    await tester.tap(find.text('液态流光'));
    await _settle(tester);
    expect(
      container.read(accentProvider).primary,
      AppAccent.forKind(BackgroundKind.liquidBloom).primary,
    );
    expect(container.read(accentProvider).source, '液态流光');
  });

  testWidgets('标题栏不再有 高端 / 均衡 / 省电 档位切换', (WidgetTester tester) async {
    await _pumpApp(tester);

    expect(find.text('高端'), findsNothing);
    expect(find.text('均衡'), findsNothing);
    expect(find.text('省电'), findsNothing);
    // 播放页结构不受影响
    expect(find.text('未在播放'), findsOneWidget);
    expect(find.text('播放队列'), findsNWidgets(2));
  });

  testWidgets('开启边框高光流动后，面板里的按钮仍然点得动', (WidgetTester tester) async {
    // 回归用例：高光描边是画在内容**之上**的一层，如果没套 IgnorePointer
    // 就会把整块面板的点击吃掉（0.0.10 报的 bug）。
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: GlassPanel(
                sweep: true,
                showSweepAt: true,
                child: Center(
                  child: TextButton(
                    onPressed: () => taps++,
                    child: const Text('点我'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('点我'), warnIfMissed: false);
    await tester.pump();

    expect(taps, 1, reason: '高光层不应拦截点击');
  });

  testWidgets('GlassPanel 能在无性能作用域时自行兜底', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: GlassPanel(child: Center(child: Text('无作用域也能渲染'))),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('无作用域也能渲染'), findsOneWidget);
  });
}

/// 拦截所有 HTTP 请求，避免测试期发起真实网络访问。
class _NoNetworkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _NoNetworkHttpClient();
}

class _NoNetworkHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const SocketException('测试环境禁止网络访问');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
