/// 主页面架构：手机/平板双端自适应导航 + Mini 播放条。
///
/// 布局规范（需求）：
///  - Mini 样式 = compact（紧凑极简）：嵌入底部导航栏「发现 ⇄ 我的」中间；
///  - 其余样式（classic/overlay/wide）：悬浮于导航栏上方（维持之前的设计），
///    背景与边框全透明；
///  - 平板（宽度 >= 600dp）：左侧 NavigationRail，右侧内容区底部 MiniPlayer；
///  - IndexedStack 保持各 Tab 状态（列表滚动位置等）。
///
/// 通知栏点击（需求）：点击媒体通知的封面区域 → 跳转音乐播放界面（封面视图）。
/// audio_service 会在通知点击时向 Dart 发出 notificationClicked 事件，
/// 于此监听并经 go_router 打开全屏播放页（有队列时）。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/router.dart' show openFullPlayer;
import '../../../core/widgets/liquid_glass_container.dart'
    show LiquidGlassBarPanel;
import '../../discover/presentation/discover_page.dart';
import '../../library/presentation/my_music_page.dart';
import '../../player/domain/np_settings.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../../player/providers/np_settings_providers.dart';
import '../../player/providers/player_providers.dart';

/// 当前 Tab
final NotifierProvider<TabNotifier, int> selectedTabProvider =
    NotifierProvider<TabNotifier, int>(TabNotifier.new);

class TabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

class MainScaffold extends ConsumerStatefulWidget {
  const MainScaffold({super.key});

  static const List<Widget> _pages = <Widget>[
    DiscoverPage(),
    MyMusicPage(),
  ];

  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold> {
  StreamSubscription<bool>? _notifClickSub;

  /// 播放页是否已由本监听打开（防止重复 push）
  bool _playerOpen = false;

  /// 需求：退出时再按一次退出 —— 首次返回提示，2 秒内再次返回才退出
  DateTime _lastBackAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _handleExitIntent() {
    final DateTime now = DateTime.now();
    if (now.difference(_lastBackAt) < const Duration(seconds: 2)) {
      // 二次返回：真正退出应用（结束 Activity 与后台音频服务由系统回收）
      unawaited(SystemNavigator.pop());
      return;
    }
    _lastBackAt = now;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('再按一次退出应用'),
        duration: Duration(milliseconds: 1600),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // 通知栏点击 → 打开播放界面（封面视图）。
    // ValueStream 是 BehaviorSubject：冷启动若由通知点击拉起，会重放 true，
    // 同样落入本逻辑 —— 行为正确（点通知进来就该看到播放页）。
    _notifClickSub = AudioService.notificationClicked.listen((bool clicked) {
      if (!clicked || !mounted) return;
      if (_playerOpen) return;
      if (!ref.read(hasQueueProvider)) return;
      _playerOpen = true;
      openFullPlayer(context).whenComplete(() => _playerOpen = false);
    });
  }

  @override
  void dispose() {
    _notifClickSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int tab = ref.watch(selectedTabProvider);
    final MiniPlayerStyle miniStyle = ref
        .watch(npSettingsProvider.select((NpPlayerSettings s) => s.miniStyle));

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool isWide = constraints.maxWidth >= AppConstants.wideBreakpoint;

        if (isWide) {
          return _tabletScaffold(context, ref, tab);
        }
        return _phoneScaffold(context, ref, tab, miniStyle);
      },
    );
  }

  // ---------------------------------------------------------------- 平板

  Widget _tabletScaffold(BuildContext context, WidgetRef ref, int tab) {
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _handleExitIntent();
      },
      child: Scaffold(
        body: SafeArea(
          child: Row(
            children: <Widget>[
              _RailNav(
                selectedIndex: tab,
                onSelect: (int i) =>
                    ref.read(selectedTabProvider.notifier).select(i),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: IndexedStack(
                          index: tab, children: MainScaffold._pages),
                    ),
                    // 需求：平板 Mini 条同样带 上滑放大/下滑缩小 出入动画
                    MiniBarSwitcher(
                      visible: ref.watch(hasQueueProvider),
                      child: const MiniPlayer(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 手机

  Widget _phoneScaffold(
    BuildContext context,
    WidgetRef ref,
    int tab,
    MiniPlayerStyle miniStyle,
  ) {
    final bool navEmbedded = miniInNavBar(miniStyle);
    final bool hasQueue = ref.watch(hasQueueProvider);

    final Widget navBar = _CenterNavBar(
      selectedIndex: tab,
      onSelect: (int i) => ref.read(selectedTabProvider.notifier).select(i),
      center: navEmbedded && hasQueue ? const MiniPlayer(embedded: true) : null,
    );

    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _handleExitIntent();
      },
      child: Scaffold(
        // 需求：底部导航栏真透明液态玻璃 —— extendBody 让页面内容延伸到
        // 导航栏/悬浮 Mini 条背后，BackdropFilter 才有真实内容可采样模糊，
        // 否则玻璃底色只剩 Scaffold 背景色（看起来就是一块不透明黑板）。
        extendBody: true,
        body: IndexedStack(index: tab, children: MainScaffold._pages),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 需求：悬浮 Mini 条（经典条）出现/消失带 上滑放大/下滑缩小 动画，
            // 与全局宿主（子页面）共用 MiniBarSwitcher，显隐规则一致
            MiniBarSwitcher(
              visible: !navEmbedded && hasQueue,
              child: const MiniPlayer(embedded: false),
            ),
            navBar,
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- 中央导航栏

/// 底部导航：发现 | 中央 Mini 播放条（可选） | 我的。
/// 全透明无 elevation；中央槽位由 Mini 播放条填充（无边框透明）。
class _CenterNavBar extends StatelessWidget {
  const _CenterNavBar({
    required this.selectedIndex,
    required this.onSelect,
    required this.center,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final Widget? center;

  static const double _height = 64;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color active = theme.colorScheme.onSurface;
    final Color inactive =
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);

    Widget item(int index, IconData outline, IconData filled, String label) {
      final bool selected = selectedIndex == index;
      return Expanded(
        child: InkWell(
          onTap: () => onSelect(index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (Widget child, Animation<double> anim) =>
                    ScaleTransition(
                  scale: anim,
                  child: child,
                ),
                child: Icon(
                  selected ? filled : outline,
                  key: ValueKey<bool>(selected),
                  size: 24,
                  color: selected ? active : inactive,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? active : inactive,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      // 第十二批需求：液态玻璃导航栏 = Mini 条同款 —— 悬浮胶囊造型，
      // 左右留 14、底部留 安全区+8，内容从胶囊四周及背后穿过
      //（Scaffold extendBody:true 已开，BackdropFilter 采样真实内容）
      color: Colors.transparent,
      padding: EdgeInsets.fromLTRB(
          14, 0, 14, MediaQuery.paddingOf(context).bottom + 8),
      child: _GlassNavBarSurface(
        child: SizedBox(
          height: _height,
          child: Row(
            children: <Widget>[
              item(0, Icons.explore_outlined, Icons.explore_rounded, '发现'),
              // 中央槽位：Mini 播放条（无边框透明，点击进播放页）
              SizedBox(
                width: 150,
                height: _height,
                child: Center(
                  child: center ?? const SizedBox.shrink(),
                ),
              ),
              item(1, Icons.person_outline_rounded, Icons.person_rounded, '我的'),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导航栏玻璃底板：第十二批需求 —— 与 Mini 条**同一配方**
/// （LiquidGlassBarPanel：同模糊/同圆角/同描边/同投影/同无色中性填充），
/// 降级策略一致；玻璃关闭时为半透明深色胶囊。
class _GlassNavBarSurface extends StatelessWidget {
  const _GlassNavBarSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassBarPanel(child: child);
  }
}

// ---------------------------------------------------------------- Rail

class _RailNav extends StatelessWidget {
  const _RailNav({required this.selectedIndex, required this.onSelect});

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelect,
      labelType: NavigationRailLabelType.all,
      groupAlignment: -0.85,
      leading: const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 6),
        child: _BrandBadge(),
      ),
      destinations: const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore_rounded),
          label: Text('发现'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: Text('我的'),
        ),
      ],
    );
  }
}

class _BrandBadge extends StatelessWidget {
  const _BrandBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AppConstants.brandColor,
            const Color(0xFFB31F1F),
          ],
        ),
      ),
      child:
          const Icon(Icons.music_note_rounded, color: Colors.white, size: 22),
    );
  }
}
