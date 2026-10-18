/// 应用入口。
///
/// ⚠️ 避坑指南 5（极度重要）：
/// AudioHandler 必须在最顶层初始化并注入 ProviderScope——
/// 全 App 唯一的音频会话在此创建，任何页面的销毁都不影响音频流。
library;

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'features/player/providers/player_providers.dart';
import 'features/player/services/ming_audio_handler.dart';
import 'features/settings/providers/settings_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 沉浸式边到边布局
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // 1) 本地存储（同步注入，所有设置 Provider 在首帧即可读取）
  // 容错：存储引擎异常（插件被裁剪/磁盘故障/损坏数据）时降级为
  // 内存存储 —— 应用仍可启动播放，仅设置不跨启动持久；绝不黑屏。
  // 等价于官方 setMockInitialValues 的公开 API 写法（后者标记为
  // visibleForTesting，生产代码改用平台接口直接注入，语义相同）。
  SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (e) {
    debugPrint('SharedPreferences 不可用，降级为内存存储: $e');
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.withData(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  }

  // 2) 系统级音频焦点管理（audio_session）：
  //    音乐会话配置 —— 播放时请求音频焦点、插耳机自动恢复、
  //    电话铃声打断时自动淡出暂停、被打断恢复后继续播放。
  //    just_audio 检测到 audio_session 依赖后自动接管焦点事件。
  try {
    final AudioSession session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (e) {
    debugPrint('audio_session 初始化失败（忽略，不影响播放）: $e');
  }

  // 3) Android 13+ 通知权限（通知栏媒体控制的前提）
  if (!kIsWeb && Platform.isAndroid) {
    try {
      await Permission.notification.request();
    } catch (_) {
      // 权限被拒不影响应用内播放，仅通知栏控制不可用
    }
  }

  // 4) 全局唯一 AudioHandler（生命周期 = App 生命周期）
  final MingAudioHandler audioHandler = await AudioService.init(
    builder: MingAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: AppConstants.notificationChannelId,
      androidNotificationChannelName: 'MingMusic 播放',
      androidNotificationChannelDescription: '后台播放与锁屏控制',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      notificationColor: AppConstants.brandColor,
    ),
  );

  runApp(
    ProviderScope(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const _MingMusicBootstrap(),
    ),
  );
}

/// 启动后异步恢复上次的播放队列（不自动播放，只回填 UI 列表）
class _MingMusicBootstrap extends ConsumerStatefulWidget {
  const _MingMusicBootstrap();

  @override
  ConsumerState<_MingMusicBootstrap> createState() =>
      _MingMusicBootstrapState();
}

class _MingMusicBootstrapState extends ConsumerState<_MingMusicBootstrap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(playerProvider.notifier).restoreQueue();
    });
  }

  @override
  Widget build(BuildContext context) => const MingMusicApp();
}
