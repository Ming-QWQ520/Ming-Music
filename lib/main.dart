/// 应用入口。
///
/// ⚠️ 避坑指南 5（极度重要）：
/// AudioHandler 必须在最顶层初始化并注入 ProviderScope——
/// 全 App 唯一的音频会话在此创建，任何页面的销毁都不影响音频流。
library;

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final SharedPreferences prefs = await SharedPreferences.getInstance();

  // 2) Android 13+ 通知权限（通知栏媒体控制的前提）
  if (!kIsWeb && Platform.isAndroid) {
    try {
      await Permission.notification.request();
    } catch (_) {
      // 权限被拒不影响应用内播放，仅通知栏控制不可用
    }
  }

  // 3) 全局唯一 AudioHandler（生命周期 = App 生命周期）
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
      child: const MingMusicApp(),
    ),
  );
}
