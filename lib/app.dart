/// 应用根 Widget：主题模式 + go_router 路由入口 + 全局 Mini 播放条宿主。
library;

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
    return MaterialApp.router(
      title: AppTitle.text,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
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
///  - 监听 go_router 当前路径：`/`（主骨架，Mini 已在导航栏内）与
///    `/player`（全屏播放页本身）不重复显示；其余页面悬浮显示；
///  - 悬浮条带半透明深色胶囊底 + 圆角（子页面无导航栏，透明条会与
///    内容混色难以辨认），左下右 12px 边距，落在安全区之上。
class _GlobalMiniBarHost extends ConsumerStatefulWidget {
  const _GlobalMiniBarHost({required this.child});

  final Widget? child;

  @override
  ConsumerState<_GlobalMiniBarHost> createState() => _GlobalMiniBarHostState();
}

class _GlobalMiniBarHostState extends ConsumerState<_GlobalMiniBarHost> {
  String _path = '/';

  void _onRouteChanged() {
    final String next = appRouter.routeInformationProvider.value.uri.path;
    if (next == _path) return;
    setState(() => _path = next);
  }

  @override
  void initState() {
    super.initState();
    appRouter.routeInformationProvider.addListener(_onRouteChanged);
    _path = appRouter.routeInformationProvider.value.uri.path;
  }

  @override
  void dispose() {
    appRouter.routeInformationProvider.removeListener(_onRouteChanged);
    super.dispose();
  }

  bool get _showFloat {
    if (_path == '/' || _path.startsWith('/player')) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final Widget child = widget.child ?? const SizedBox.shrink();
    final bool hasQueue = ref.watch(hasQueueProvider);

    return Stack(
      children: <Widget>[
        child,
        // 全局悬浮 Mini 条（子页面专属；主骨架与播放页由各自层级负责）
        if (_showFloat && hasQueue)
          Positioned(
            left: 12,
            right: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 6,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.58),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                ),
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
