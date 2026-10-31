/// 应用入口。
///
/// ⚠️ 避坑指南 5（极度重要）：
/// AudioHandler 必须在最顶层初始化并注入 ProviderScope——
/// 全 App 唯一的音频会话在此创建，任何页面的销毁都不影响音频流。
///
/// ⚠️ 灰屏修复（2026-10）：
/// 历史版本 main() 中任何一环 await 卡死/抛异常都会导致 runApp 永远
/// 不执行 —— 用户看到的是 Activity 启动背景的纯灰屏。现全链路改为
/// 「独立容错 + 超时上限」：任何初始化失败都只降级对应功能，绝不阻塞
/// 首帧；通知权限申请移至首帧之后（部分 ROM 的权限弹窗曾把启动卡住
/// 38 秒）；全程诊断打点落盘（设置 → 运行诊断 可查看）。
library;

import 'dart:async' show unawaited;
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
import 'core/utils/diag.dart';
import 'core/widgets/cover_image.dart';
import 'features/listen/services/deep_link_service.dart';
import 'features/player/providers/player_providers.dart';
import 'features/player/services/ming_audio_handler.dart';
import 'features/settings/providers/settings_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0) 诊断钩子最先安装：之后任何异常都有据可查
  Diag.installHooks();
  await Diag.init();
  Diag.milestone('binding ready');
  Diag.log(
      '设备: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');

  // 0.5) 全局 HTTP User-Agent 覆写（网易 CDN 403 的全局兑底）：
  // 网易 CDN 对 Dart 默认 UA（Dart/x.x）风控 403 —— 任何遗漏 UA 的
  // 直连请求（如裸 NetworkImage 头像）都会加载失败。全局覆写为浏览器
  // UA 后全部放行；已显式设置过 headers 的请求不受影响。
  HttpOverrides.global = _BrowserUaHttpOverrides();

  // 1) 沉浸式边到边布局（失败仅影响观感，不阻塞）
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    Diag.log('edgeToEdge 失败（忽略）: $e');
  }
  Diag.milestone('edgeToEdge done');

  // 2) 本地存储（同步注入，所有设置 Provider 在首帧即可读取）
  // 容错：存储引擎异常（插件被裁剪/磁盘故障/损坏数据）时降级为
  // 内存存储 —— 应用仍可启动播放，仅设置不跨启动持久；绝不灰屏。
  // 等价于官方 setMockInitialValues 的公开 API 写法（后者标记为
  // visibleForTesting，生产代码改用平台接口直接注入，语义相同）。
  SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance()
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    Diag.log('SharedPreferences 异常，降级为内存存储: $e');
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.withData(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  }
  Diag.milestone('prefs ready');

  // 3) 系统级音频焦点管理（audio_session）：
  //    音乐会话配置 —— 播放时请求音频焦点、插耳机自动恢复、
  //    电话铃声打断时自动淡出暂停、被打断恢复后继续播放。
  //    just_audio 检测到 audio_session 依赖后自动接管焦点事件。
  try {
    final AudioSession session =
        await AudioSession.instance.timeout(const Duration(seconds: 3));
    await session
        .configure(const AudioSessionConfiguration.music())
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    Diag.log('audio_session 初始化失败（忽略，不影响播放）: $e');
  }
  Diag.milestone('audio_session done');

  // 4) 全局唯一 AudioHandler（生命周期 = App 生命周期）
  // 降级链：AudioService.init 失败（媒体会话/通道异常）→ 裸构造内核，
  // 应用内播放完全可用，仅系统通知栏/蓝牙控制暂不可用。
  MingAudioHandler audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: MingAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: AppConstants.notificationChannelId,
        androidNotificationChannelName: 'MingMusic 播放',
        androidNotificationChannelDescription: '后台播放与锁屏控制',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        notificationColor: AppConstants.brandColor,
      ),
    ).timeout(const Duration(seconds: 8));
  } catch (e) {
    Diag.log('AudioService.init 失败，降级为裸内核: $e');
    // 裸构造路径同样可能失败（如 just_audio 平台层初始化异常）——
    // 该路径从未在部分机型上验证过，必须独立容错并留痕：
    // 失败信息写入诊断文件（外部镜像可被用户直接取走），随后上抛
    // 交由 PlatformDispatcher.onError 记录；屏幕停留启动背景时，
    // 原生看门狗会弹出启动诊断对话框展示日志尾部（见 MainActivity）。
    try {
      audioHandler = MingAudioHandler();
    } catch (e2, st2) {
      Diag.log('裸内核构造也失败: $e2');
      Diag.log(
          '  stack(首5帧): ${st2.toString().split('\n').take(5).join(' | ')}');
      rethrow;
    }
  }
  Diag.milestone('audioHandler ready');

  runApp(
    ProviderScope(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const _MingMusicBootstrap(),
    ),
  );
  Diag.milestone('runApp done —— 首帧开始构建');

  // 5) Android 13+ 通知权限：移到首帧之后异步申请。
  // （部分 ROM 的权限弹窗曾把 main() 阻塞数十秒 —— 用户看到的就是灰屏）
  if (!kIsWeb && Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      () async {
        try {
          final PermissionStatus s = await Permission.notification
              .request()
              .timeout(const Duration(seconds: 10));
          Diag.log('通知权限申请结果: $s');
        } catch (e) {
          Diag.log('通知权限申请失败（忽略）: $e');
        }
      }();
      // 6) 一起听邀请深链（第二十五批）：首帧后初始化，
      // 冷启动 getInitialLink / 热启动 uriLinkStream，全链路容错不阻塞
      () async {
        try {
          await DeepLinkService.init();
          Diag.milestone('deepLink ready');
        } catch (e) {
          Diag.log('深链初始化失败（忽略）: $e');
        }
      }();
    });
  } else {
    // 非 Android 平台同样初始化（桌面端 web 协议唤起，失败静默）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(DeepLinkService.init());
    });
  }
}

/// 全局 HTTP 客户端覆写：统一浏览器 UA（网易 CDN 403 兑底，见 main 步骤 0.5）。
/// 仅改 User-Agent；证书校验等其余行为保持默认，不降低安全性。
class _BrowserUaHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final HttpClient client = super.createHttpClient(context);
    client.userAgent = CoverImage.kImageUserAgent;
    return client;
  }
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
      // restoreQueue 内部已分段容错；此处再兜一层：任何漏网异常
      // 只记诊断日志，绝不影响 UI。
      () async {
        try {
          await ref.read(playerProvider.notifier).restoreQueue();
          Diag.milestone('restoreQueue done');
        } catch (e, st) {
          Diag.log('restoreQueue 异常: $e');
          Diag.log(
              '  stack(首5帧): ${st.toString().split('\n').take(5).join(' | ')}');
        }
      }();
    });
  }

  @override
  Widget build(BuildContext context) => const MingMusicApp();
}
