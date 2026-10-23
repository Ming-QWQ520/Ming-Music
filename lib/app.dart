/// 应用根 Widget：主题模式 + go_router 路由入口 + 全局 Mini 播放条宿主。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme/app_theme.dart';
import 'features/player/presentation/widgets/mini_player.dart';
import 'features/player/providers/player_providers.dart';
import 'features/settings/providers/settings_providers.dart';

class MingMusicApp extends ConsumerWidget {
  const MingMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(themeModeProvider);
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
      builder: (BuildContext context, Widget? child) =>
          _GlobalMiniBarHost(child: child),
    );
  }
}

/// 全局 Mini 播放条宿主：
///  - 监听 go_router `routerDelegate`（而非 routeInformationProvider）：
///    push 与 **pop 都必然回调**，当前路径取自 `currentConfiguration.uri`，
///    彻底修复「子页面打开播放页再退出后 Mini 条消失」——旧实现依赖
///    routeInformationProvider 的 location 通知，pop 回退在部分机型上
///    不再触发监听，路径残留 `/player` 导致悬浮条再也不出现；
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
  String _path = '/';

  void _onRouteChanged() {
    final String next = appRouter.routerDelegate.currentConfiguration.uri.path;
    if (next == _path) return;
    setState(() => _path = next);
  }

  @override
  void initState() {
    super.initState();
    appRouter.routerDelegate.addListener(_onRouteChanged);
    _path = appRouter.routerDelegate.currentConfiguration.uri.path;
  }

  @override
  void dispose() {
    appRouter.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  bool get _showFloat {
    if (_path.startsWith('/player')) return false;
    if (_path == '/' || _path.isEmpty) return false;
    return true;
  }

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
