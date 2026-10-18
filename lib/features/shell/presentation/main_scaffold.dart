/// 主页面架构：手机/平板双端自适应导航 + 悬浮 Mini 播放条。
///
/// 两个 Tab：发现（网易云首页风格）/ 我的（仿网易云，集成登录与设置）。
///
/// 布局规范：
///  - 手机（宽度 < 600dp）：底部 NavigationBar，Mini 播放条悬浮于其上方；
///  - 平板（宽度 >= 600dp）：左侧 NavigationRail，右侧内容区底部 MiniPlayer；
///  - IndexedStack 保持各 Tab 状态（列表滚动位置等）。
///
/// 通知栏点击（需求）：点击媒体通知的封面区域 → 跳转音乐播放界面（封面视图）。
/// audio_service 会在通知点击时向 Dart 发出 notificationClicked 事件，
/// 于此监听并 push 全屏播放页（有队列时）。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../discover/presentation/discover_page.dart';
import '../../library/presentation/my_music_page.dart';
import '../../player/presentation/full_player_page.dart';
import '../../player/presentation/widgets/mini_player.dart';
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
      Navigator.of(context)
          .push<void>(FullPlayerRoute<void>())
          .whenComplete(() => _playerOpen = false);
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

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool isWide = constraints.maxWidth >= AppConstants.wideBreakpoint;

        if (isWide) {
          return _tabletScaffold(context, ref, tab);
        }
        return _phoneScaffold(context, ref, tab);
      },
    );
  }

  // ---------------------------------------------------------------- 平板

  Widget _tabletScaffold(BuildContext context, WidgetRef ref, int tab) {
    return Scaffold(
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
                  const MiniPlayer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 手机

  Widget _phoneScaffold(BuildContext context, WidgetRef ref, int tab) {
    return Scaffold(
      body: IndexedStack(index: tab, children: MainScaffold._pages),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const MiniPlayer(),
          NavigationBar(
            height: 64,
            selectedIndex: tab,
            onDestinationSelected: (int i) =>
                ref.read(selectedTabProvider.notifier).select(i),
            destinations: const <Widget>[
              NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore_rounded),
                label: '发现',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: '我的',
              ),
            ],
          ),
        ],
      ),
    );
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
