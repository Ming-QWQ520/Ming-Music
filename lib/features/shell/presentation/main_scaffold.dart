/// 主页面架构：手机/平板双端自适应导航 + 悬浮 Mini 播放条。
///
/// 布局规范：
///  - 手机（宽度 < 600dp）：底部 MD3 NavigationBar，
///    Mini 播放条悬浮于导航栏上方；
///  - 平板（宽度 >= 600dp）：左侧 MD3 NavigationRail，
///    右侧 Expanded 内容区；Mini 播放条**限制在右侧内容区底部**，
///    不覆盖左侧导航栏；
///  - IndexedStack 保持各 Tab 状态（列表滚动位置等）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../library/presentation/favorites_page.dart';
import '../../library/presentation/library_page.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../../settings/presentation/settings_page.dart';

/// 当前 Tab
final NotifierProvider<TabNotifier, int> selectedTabProvider =
    NotifierProvider<TabNotifier, int>(TabNotifier.new);

class TabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

class MainScaffold extends ConsumerWidget {
  const MainScaffold({super.key});

  static const List<Widget> _pages = <Widget>[
    LibraryPage(),
    FavoritesPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            // 左侧 NavigationRail
            _RailNav(
              selectedIndex: tab,
              onSelect: (int i) =>
                  ref.read(selectedTabProvider.notifier).select(i),
            ),
            const VerticalDivider(width: 1),
            // 右侧内容区：内容 + 底部 Mini 播放条（不覆盖 Rail）
            Expanded(
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: IndexedStack(index: tab, children: _pages),
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
      body: IndexedStack(index: tab, children: _pages),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (int i) =>
                ref.read(selectedTabProvider.notifier).select(i),
            destinations: const <Widget>[
              _LibraryDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music_rounded),
                label: '音乐库',
              ),
              _LibraryDestination(
                icon: Icon(Icons.favorite_outline_rounded),
                selectedIcon: Icon(Icons.favorite_rounded),
                label: '收藏',
              ),
              _LibraryDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: '设置',
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
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music_rounded),
          label: Text('音乐库'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.favorite_outline_rounded),
          selectedIcon: Icon(Icons.favorite_rounded),
          label: Text('收藏'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: Text('设置'),
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
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF8B7CF6), Color(0xFF5B2FD1)],
        ),
      ),
      child:
          const Icon(Icons.music_note_rounded, color: Colors.white, size: 22),
    );
  }
}

/// 类型别名，简化 NavigationBar destinations 声明
typedef _LibraryDestination = NavigationDestination;
