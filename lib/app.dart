/// 应用根 Widget：主题模式 + go_router 路由入口 + 全局 Mini 播放条宿主。
library;

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart' show RouteMatchBase;

import 'core/router.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/app_notify.dart';
import 'features/auth/providers/auth_providers.dart';
import 'features/discover/data/netease_providers.dart' show cloudDriveProvider;
import 'features/player/presentation/widgets/mini_player.dart';
import 'features/player/providers/player_providers.dart';
import 'features/settings/providers/settings_providers.dart';

class MingMusicApp extends ConsumerWidget {
  const MingMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(themeModeProvider);
    // 第十五批需求：登录后自动同步音乐云盘 —— 监听登录态，变为已登录
    // （含启动恢复与首次扫码/手机登录）时预热云盘快照 provider，
    // 云盘页与我的页云盘 tile 打开即显示歌曲；失败静默（可下拉重试）
    ref.listen<AuthState>(authProvider, (AuthState? prev, AuthState next) {
      if (next.loggedIn && (prev?.loggedIn != true)) {
        // 静默预热：失败不阻断 UI，进云盘页/下拉可重试
        unawaited(ref
            .read(cloudDriveProvider.future)
            .then<void>((_) {}, onError: (Object _) {}));
      }
    });
    // 需求：LRU 缓存上限/开关 → SongCacheService 同步（应用级常驻）
    ref.watch(cacheConfigSyncProvider);
    // 需求：全局图片背景（除播放页外）—— 启用时页面底色透明化，
    // 背景图层铺在 Router 之下（BackdropFilter 仍可采样到）
    final AppBackgroundConfig appBg = ref.watch(appBackgroundProvider);
    final bool bgEnabled = appBg.enabled && (appBg.imagePath != null);
    return MaterialApp.router(
      title: AppTitle.text,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(transparentScaffold: bgEnabled),
      darkTheme: AppTheme.dark(transparentScaffold: bgEnabled),
      themeMode: mode,
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[
        Locale('zh'),
        Locale('en'),
      ],
      locale: const Locale('zh'),
      routerConfig: appRouter,
      // 需求「Mini 播放条始终在各个界面显示」：全局宿主包裹 Navigator，
      // 除主骨架（自带导航栏内嵌 Mini 条）与全屏播放页（本身就是播放器）
      // 之外的所有页面都悬浮显示 Mini 播放条。
      // 需求（第二十四批）：AppNotifyHost 挂在最顶层 —— 应用内通知
      // 覆盖 Navigator 与全部弹层/播放条，替代 Flutter 原生 SnackBar。
      builder: (BuildContext context, Widget? child) =>
          AppNotifyHost(child: _GlobalMiniBarHost(child: child)),
    );
  }
}

/// 全局 Mini 播放条宿主：
///  - 监听 go_router `routerDelegate`（而非 routeInformationProvider）：
///    push 与 **pop 都必然回调**，栈结构取自 `currentConfiguration.matches`；
///  - ⚠️ 显隐判定必须用 matches 而非 uri（修复「进入非首页页面 Mini 条
///    不显示」）：go_router 14.x 的 `RouteMatchList.uri` 只反映
///    **非 ImperativeRouteMatch** 的匹配 —— `context.push()` 产生的正是
///    ImperativeRouteMatch（见 go_router match.dart 源码注释 "This uri
///    only reflects RouteMatchs that are not ImperativeRouteMatch"），
///    push 后 `currentConfiguration.uri.path` 仍停在 `/`，旧实现据此
///    判定"仍在首页"，悬浮条在所有子页面永不出现；
///    `matches` 则包含被 push 的匹配，栈深度与路径均正确；
///  - `/`（主骨架，Mini 已在导航栏内/悬浮位）与 `/player`（全屏播放页
///    本身）不重复显示；其余页面统一显示；
///  - 出现/消失带 MiniBarSwitcher 动画（上滑放大进场 / 下滑缩小退场）。
class _GlobalMiniBarHost extends ConsumerStatefulWidget {
  const _GlobalMiniBarHost({required this.child});

  final Widget? child;

  @override
  ConsumerState<_GlobalMiniBarHost> createState() => _GlobalMiniBarHostState();
}

class _GlobalMiniBarHostState extends ConsumerState<_GlobalMiniBarHost> {
  int _stackDepth = 1;
  bool _playerOpen = false;

  /// 需求：设置界面不显示底部 Mini 条
  bool _settingsOpen = false;

  void _onRouteChanged() {
    final List<RouteMatchBase> matches =
        appRouter.routerDelegate.currentConfiguration.matches;
    final int depth = matches.length;
    final bool playerOpen =
        matches.any((RouteMatchBase m) => m.matchedLocation == '/player');
    final bool settingsOpen =
        matches.any((RouteMatchBase m) => m.matchedLocation == '/settings');
    if (depth == _stackDepth &&
        playerOpen == _playerOpen &&
        settingsOpen == _settingsOpen) {
      return;
    }
    setState(() {
      _stackDepth = depth;
      _playerOpen = playerOpen;
      _settingsOpen = settingsOpen;
    });
  }

  @override
  void initState() {
    super.initState();
    appRouter.routerDelegate.addListener(_onRouteChanged);
    final List<RouteMatchBase> initial =
        appRouter.routerDelegate.currentConfiguration.matches;
    _stackDepth = initial.length;
    _playerOpen =
        initial.any((RouteMatchBase m) => m.matchedLocation == '/player');
    _settingsOpen =
        initial.any((RouteMatchBase m) => m.matchedLocation == '/settings');
  }

  @override
  void dispose() {
    appRouter.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  /// 显隐判定（需求：进入非首页页面正常显示 Mini 条）：
  ///  - 栈深度 == 1：在主骨架（Mini 条已由导航栏内/悬浮位负责）→ 不重复显示；
  ///  - 栈内有 '/player'：全屏播放页本身就是播放器 → 不显示；
  ///  - 栈内有 '/settings'：需求 —— 设置界面不显示底部 Mini 条；
  ///  - 其余（任意子页面，无论 push 多少层）→ 显示。
  bool get _showFloat => _stackDepth > 1 && !_playerOpen && !_settingsOpen;

  @override
  Widget build(BuildContext context) {
    final Widget child = widget.child ?? const SizedBox.shrink();
    final bool hasQueue = ref.watch(hasQueueProvider);
    // 需求：全局图片背景（除播放页外）——铺在 Router 之下，页面 Scaffold
    // 底色透明化后透出；播放页背景由 PlayerBackground 自绘不透出。
    final AppBackgroundConfig appBg = ref.watch(appBackgroundProvider);
    final bool bgEnabled = appBg.enabled && (appBg.imagePath != null);

    final Widget? bg = bgEnabled
        ? Positioned.fill(
            child: Image.file(
              File(appBg.imagePath!),
              fit: BoxFit.cover,
              // 轻压暗保证前景文字可读性
              color: Colors.black.withValues(alpha: 0.25),
              colorBlendMode: BlendMode.darken,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          )
        : null;

    return Stack(
      children: <Widget>[
        if (bg != null) bg,
        child,
        // 全局悬浮 Mini 条（子页面专属；主骨架与播放页由各自层级负责）。
        // 需求：显隐一致性 —— 只要队列存在且不在播放页就显示，出现/消失
        // 统一走 MiniBarSwitcher（上滑放大进场 / 下滑缩小退场）。
        Positioned(
          left: 12,
          right: 12,
          bottom: MediaQuery.paddingOf(context).bottom + 6,
          child: Material(
            color: Colors.transparent,
            child: MiniBarSwitcher(
              visible: _showFloat && hasQueue,
              child: const MiniPlayer(embedded: false),
            ),
          ),
        ),
      ],
    );
  }
}

class AppTitle {
  AppTitle._();

  static const String text = 'MingMusic';
}
