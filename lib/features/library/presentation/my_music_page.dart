/// 我的页（仿 kgka_Music_hl LibraryPage 布局重写）：
///
///  - 顶栏：大标题「我的」+ 新建歌单 + 设置（kgka 顶栏动作）；
///  - 用户资料头部：圆形头像 + 昵称 + 登录状态点（点击进入个人主页，对齐
///    Zephyr ProfileView 的数据与 API）；
///  - 2x2 功能宫格（kgka _LibraryQuickGrid）：我喜欢的音乐 / 最近播放 /
///    本地音乐 / 音乐云盘，渐变图标块 + 按压缩放；
///  - 功能行：听歌排行榜（对齐 kgka 折叠分组之外的入口行）；
///  - 折叠分组：创建的歌单 / 收藏的歌单（AnimatedCrossFade，显示歌单封面，
///    对齐需求：歌单需要显示歌单封面）；「我的云盘」折叠项；
///  - 未登录 → 登录引导卡；校验失败 → 重试卡（对齐 Zephyr 容错策略）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/netease_models.dart'
    show PlaylistMeta, CloudDriveInfo;
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/data/netease_auth_repository.dart' show NeteaseUserPlaylist;
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart';
import '../../discover/data/netease_providers.dart';
import '../../settings/domain/settings_models.dart' show LibraryPlaylistLayout;
import '../../settings/providers/settings_providers.dart'
    show libraryPlaylistLayoutProvider;
import '../../player/presentation/cache_songs_page.dart';
import '../../player/providers/player_providers.dart';

class MyMusicPage extends ConsumerStatefulWidget {
  const MyMusicPage({super.key});

  @override
  ConsumerState<MyMusicPage> createState() => _MyMusicPageState();
}

class _MyMusicPageState extends ConsumerState<MyMusicPage> {
  List<NeteaseUserPlaylist>? _playlists;
  bool _createdExpanded = true;
  bool _collectedExpanded = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPlaylists());
  }

  Future<void> _loadPlaylists() async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) {
      if (mounted) setState(() => _playlists = null);
      return;
    }
    try {
      final List<NeteaseUserPlaylist> list = await ref
          .read(neteaseAuthRepositoryProvider)
          .userPlaylists(auth.profile!.userId);
      if (mounted) setState(() => _playlists = list);
    } catch (_) {
      if (mounted) setState(() => _playlists = const <NeteaseUserPlaylist>[]);
    }
  }

  Future<void> _refresh() async {
    await ref.read(authProvider.notifier).refreshExtras();
    await _loadPlaylists();
  }

  Future<void> _openLogin(BuildContext context) async {
    await showLoginSheet(context);
    if (!mounted) return;
    if (ref.read(authProvider).loggedIn) _loadPlaylists();
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final TextEditingController ctrl = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration:
              const InputDecoration(hintText: '请输入歌单名称', counterText: ''),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    try {
      final int id =
          await ref.read(neteaseRepositoryProvider).playlistCreate(name);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已创建歌单「$name」')));
      _loadPlaylists();
      if (id > 0) {
        context.push('/playlist/$id?name=${Uri.encodeComponent(name)}');
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AuthState auth = ref.watch(authProvider);
    // 需求：宫格/列表排序切换（默认宫格，持久化）
    final LibraryPlaylistLayout layout =
        ref.watch(libraryPlaylistLayoutProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          '我的',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        actions: <Widget>[
          if (auth.loggedIn)
            IconButton(
              tooltip:
                  layout == LibraryPlaylistLayout.grid ? '切换为列表排序' : '切换为宫格排序',
              icon: Icon(
                layout == LibraryPlaylistLayout.grid
                    ? Icons.view_list_rounded
                    : Icons.grid_view_rounded,
                size: 23,
              ),
              onPressed: () =>
                  ref.read(libraryPlaylistLayoutProvider.notifier).toggle(),
            ),
          if (auth.loggedIn)
            IconButton(
              tooltip: '新建歌单',
              icon: const Icon(Icons.add_rounded, size: 26),
              onPressed: () => _createPlaylist(context),
            ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_rounded, size: 23),
            onPressed: () => context.push('/settings'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: AppConstants.brandColor,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          // 需求：extendBody 后底部留白须覆盖 导航栏64 + Mini条70 + 安全区，
          // 末尾内容可完整滚出玻璃条
          padding: EdgeInsets.only(
              top: 4, bottom: MediaQuery.paddingOf(context).bottom + 170),
          children: <Widget>[
            _ProfileHeader(
              loggedIn: auth.loggedIn,
              statusCheckFailed: auth.statusCheckFailed,
              likesCount: auth.loggedIn ? auth.likedIds.length : null,
              onRetry: () => ref.read(authProvider.notifier).recheckLogin(),
              onLogin: () => _openLogin(context),
            ),
            const SizedBox(height: 6),
            // 2x2 功能宫格（kgka）；喜欢的音乐直接开「我喜欢的音乐」歌单
            // （需求：与创建歌单中的我喜欢的音乐完全一致 —— 同排序同样式）
            _QuickGrid(likedPlaylist: _likedPlaylist),
            const SizedBox(height: 10),
            // 功能行：听歌排行榜
            const _RankRow(),
            // 歌单分组：宫格（创建+收藏连续排列，无收藏折叠栏）/ 列表（原折叠分组）
            if (auth.loggedIn) ...<Widget>[
              const SizedBox(height: 8),
              if (layout == LibraryPlaylistLayout.grid)
                _PlaylistGridSection(
                  playlists: <NeteaseUserPlaylist>[
                    ..._createdList,
                    ..._collectedList,
                  ],
                  createdCount: _createdList.length,
                )
              else ...<Widget>[
                _PlaylistSection(
                  header: '创建的歌单',
                  count: _createdList.length,
                  playlists: _createdList,
                  expanded: _createdExpanded,
                  onToggle: () =>
                      setState(() => _createdExpanded = !_createdExpanded),
                ),
                if (_collectedList.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  _PlaylistSection(
                    header: '收藏的歌单',
                    count: _collectedList.length,
                    playlists: _collectedList,
                    expanded: _collectedExpanded,
                    onToggle: () => setState(
                        () => _collectedExpanded = !_collectedExpanded),
                  ),
                ],
              ],
              // 需求：底部「我的云盘」行已移除 —— 云盘入口与样式
              // 已上移至顶部功能宫格的「音乐云盘」tile（登录后显示
              // 云盘歌曲数）。
              const SizedBox(height: 8),
              // 需求：我的页增加数据缓存入口（无网环境体验保障，可在此清理）
              const _CacheRow(),
            ],
            const SizedBox(height: 12),
            Center(
              child: Text(
                '下拉可刷新歌单列表',
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<NeteaseUserPlaylist> get _createdList {
    final int myUid = ref.read(authProvider).profile?.userId ?? 0;
    return (_playlists ?? const <NeteaseUserPlaylist>[])
        .where((NeteaseUserPlaylist p) => p.creatorUserId == myUid)
        .toList(growable: false);
  }

  List<NeteaseUserPlaylist> get _collectedList {
    final int myUid = ref.read(authProvider).profile?.userId ?? 0;
    return (_playlists ?? const <NeteaseUserPlaylist>[])
        .where((NeteaseUserPlaylist p) =>
            p.creatorUserId != myUid && p.creatorUserId != 0)
        .toList(growable: false);
  }

  /// 「我喜欢的音乐」歌单（网易云约定：用户第一个创建的歌单；
  /// 需求：喜欢的音乐入口与创建歌单中的我喜欢的音乐为同一页面）
  NeteaseUserPlaylist? get _likedPlaylist {
    final List<NeteaseUserPlaylist> created = _createdList;
    for (final NeteaseUserPlaylist p in created) {
      if (p.name.contains('喜欢的音乐')) return p;
    }
    return created.isEmpty ? null : created.first;
  }
}

// ---------------------------------------------------------------- 资料头部

/// 用户资料头部（kgka _UserProfileHeader）：54 圆头像（白描边）+ 昵称 +
/// 登录状态点；点击进入个人主页（Zephyr 对齐）。
class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader({
    required this.loggedIn,
    required this.statusCheckFailed,
    required this.onLogin,
    required this.onRetry,
    this.likesCount,
  });

  final bool loggedIn;
  final bool statusCheckFailed;
  final VoidCallback onLogin;
  final VoidCallback onRetry;
  final int? likesCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AuthState auth = ref.watch(authProvider);

    if (statusCheckFailed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Material(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onRetry,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  const CircleAvatar(
                    radius: 27,
                    backgroundColor: Colors.white12,
                    child: Icon(Icons.cloud_off_rounded,
                        size: 28, color: Colors.white38),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('登录状态校验失败',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        SizedBox(height: 4),
                        Text('网络异常或服务波动，登录信息已保留，点击重试',
                            style: TextStyle(fontSize: 12.5)),
                      ],
                    ),
                  ),
                  Icon(Icons.refresh_rounded,
                      size: 24, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final Widget avatar = Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.8),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: CoverImage(
          src: loggedIn ? auth.profile?.avatarUrl : null,
          size: 54,
          radius: 27,
        ),
      ),
    );

    final Widget nameCol = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            loggedIn ? (auth.profile?.nickname ?? '网易云用户') : '未登录',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: -0.3),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Container(
                width: 7.5,
                height: 7.5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: loggedIn
                      ? const Color(0xFF4CAF50)
                      : Colors.white.withValues(alpha: 0.45),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                statusCheckFailed
                    ? '校验中…'
                    : (loggedIn ? '已登录网易云音乐' : '点击登录网易云音乐'),
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: loggedIn ? () => context.push('/profile') : onLogin,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            children: <Widget>[
              avatar,
              const SizedBox(width: 14),
              nameCol,
              if (loggedIn && likesCount != null)
                Text('$likesCount首喜欢',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(width: 6),
              Icon(
                loggedIn ? Icons.chevron_right_rounded : Icons.login_rounded,
                size: 22,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    )
        .animate(delay: 30.ms)
        .fadeIn(duration: 240.ms)
        .slideY(begin: 0.05, end: 0);
  }
}

// ---------------------------------------------------------------- 功能宫格

/// 2x2 功能宫格（kgka _LibraryQuickGrid）：渐变图标块 + 标题 + 副标题，
/// 按压 AnimatedScale(0.95)。
/// 需求：喜欢的音乐 = 「我喜欢的音乐」歌单本身（同排序同封面样式），
/// 歌单未加载时回退旧喜欢列表页。
class _QuickGrid extends ConsumerWidget {
  const _QuickGrid({this.likedPlaylist});

  final NeteaseUserPlaylist? likedPlaylist;

  static const List<List<Color>> _gradients = <List<Color>>[
    <Color>[Color(0xFFFF85A1), Color(0xFFFF3366)], // 喜欢：红粉
    <Color>[Color(0xFF70B9FE), Color(0xFF2C7BF6)], // 最近：蓝
    <Color>[Color(0xFF67E3C8), Color(0xFF00BFA5)], // 本地：青
    <Color>[Color(0xFF9BE7A4), Color(0xFF4ADE80)], // 云盘：绿
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authProvider);
    final String likeSub =
        auth.loggedIn ? '${auth.likedIds.length} 首' : '登录后可用';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _QuickHubTile(
                  icon: Icons.favorite_rounded,
                  gradient: _gradients[0],
                  title: '喜欢的音乐',
                  subtitle: likeSub,
                  onTap: () {
                    final NeteaseUserPlaylist? p = likedPlaylist;
                    if (p != null) {
                      context.push(
                        '/playlist/${p.id}?name=${Uri.encodeComponent(p.name)}',
                        extra: PlaylistMeta(
                          id: p.id,
                          name: p.name,
                          coverUrl: p.coverUrl,
                          trackCount: p.trackCount,
                          creatorUserId: p.creatorUserId,
                        ),
                      );
                    } else {
                      context.push('/liked-songs');
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickHubTile(
                  icon: Icons.history_rounded,
                  gradient: _gradients[1],
                  title: '最近播放',
                  subtitle: '刚刚听过',
                  onTap: () => context.push('/recent-songs'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: _QuickHubTile(
                  icon: Icons.library_music_rounded,
                  gradient: _gradients[2],
                  title: '本地音乐',
                  subtitle: '扫描设备音频',
                  onTap: () => context.push('/local-music'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                // 需求：云盘样式上移 —— 原「我的云盘」行样式移至本 tile
                //（登录后显示云盘歌曲数），底部行已删除
                child: const _CloudDriveTile(),
              ),
            ],
          ),
        ],
      ),
    )
        .animate(delay: 70.ms)
        .fadeIn(duration: 260.ms)
        .slideY(begin: 0.05, end: 0);
  }
}

/// 音乐云盘宫格 tile（需求：原「我的云盘」行样式上移至此）——
/// 云盘绿渐变图标块 + 「音乐云盘」标题 + 登录后显示云盘歌曲数；
/// 未登录/获取失败回退「登录后可用」。点击进云盘页。
class _CloudDriveTile extends ConsumerStatefulWidget {
  const _CloudDriveTile();

  @override
  ConsumerState<_CloudDriveTile> createState() => _CloudDriveTileState();
}

class _CloudDriveTileState extends ConsumerState<_CloudDriveTile> {
  int? _count;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCount());
  }

  Future<void> _loadCount() async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return;
    try {
      final CloudDriveInfo info =
          await ref.read(neteaseRepositoryProvider).cloudInfo();
      if (!mounted) return;
      setState(() => _count = info.count);
    } catch (_) {
      // 云盘信息获取失败静默（仍可进入云盘页查看）
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authProvider);
    final String subtitle =
        auth.loggedIn && _count != null ? '$_count 首歌曲已同步' : '登录后可用';
    return _QuickHubTile(
      icon: Icons.cloud_rounded,
      gradient: const <Color>[Color(0xFF9BE7A4), Color(0xFF4ADE80)],
      title: '音乐云盘',
      subtitle: subtitle,
      onTap: () => context.push('/cloud-drive'),
    );
  }
}

class _QuickHubTile extends StatefulWidget {
  const _QuickHubTile({
    required this.icon,
    required this.gradient,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final List<Color> gradient;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_QuickHubTile> createState() => _QuickHubTileState();
}

class _QuickHubTileState extends State<_QuickHubTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: widget.gradient,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(widget.icon, size: 21, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 1),
                    Text(widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 功能行

class _RankRow extends StatelessWidget {
  const _RankRow();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/listen-rank'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: <Widget>[
                Icon(Icons.leaderboard_rounded,
                    size: 20, color: AppConstants.brandColor),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('听歌排行榜',
                      style: TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
                Text('本周 / 所有时间',
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded,
                    size: 19, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 歌单分组

/// 宫格歌单区（需求：默认宫格排序 ——
///  - 不显示收藏的歌单收起/弹出栏；
///  - 收藏的歌单从最后一个创建的歌单下按默认顺序自上而下续排；
///  - 3 列封面网格（封面 + 名称 + 曲目数），网易云「我的」样式）。
class _PlaylistGridSection extends StatelessWidget {
  const _PlaylistGridSection({
    required this.playlists,
    required this.createdCount,
  });

  /// 已按 [created..., collected...] 顺序拼接的完整列表
  final List<NeteaseUserPlaylist> playlists;

  /// 创建的歌单数量（标题计数用）
  final int createdCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: <Widget>[
                Text('创建的歌单',
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                Text('$createdCount',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          GridView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              childAspectRatio: 0.78,
            ),
            itemCount: playlists.length,
            itemBuilder: (BuildContext context, int index) =>
                _PlaylistGridCard(playlist: playlists[index]),
          ),
        ],
      ),
    );
  }
}

/// 宫格歌单卡：方形圆角封面 + 两行名称 + 曲目数
class _PlaylistGridCard extends StatelessWidget {
  const _PlaylistGridCard({required this.playlist});

  final NeteaseUserPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GestureDetector(
      onTap: () => context.push(
        '/playlist/${playlist.id}?name=${Uri.encodeComponent(playlist.name)}',
        extra: PlaylistMeta(
          id: playlist.id,
          name: playlist.name,
          coverUrl: playlist.coverUrl,
          trackCount: playlist.trackCount,
          creatorUserId: playlist.creatorUserId,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              // 第十二批需求：歌单封面 Hero —— 与歌单详情页大图同 tag，
              // 点击时封面平滑放大为详情页全屏大图
              child: Hero(
                tag: playlistCoverHeroTag(playlist.id),
                child: CoverImage(
                  src: playlist.coverUrl,
                  size: 120,
                  radius: 10,
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.25,
              color: theme.colorScheme.onSurface,
            ),
          ),
          Text(
            '${playlist.trackCount}首',
            maxLines: 1,
            style: TextStyle(
              fontSize: 10.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistSection extends StatelessWidget {
  const _PlaylistSection({
    required this.header,
    required this.count,
    required this.playlists,
    required this.expanded,
    required this.onToggle,
  });

  final String header;
  final int count;
  final List<NeteaseUserPlaylist> playlists;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                children: <Widget>[
                  AnimatedRotation(
                    turns: expanded ? 0.0 : -0.25,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more_rounded,
                        size: 20, color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 6),
                  Text(header,
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 6),
                  Text('$count',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)),
                  const Spacer(),
                  Icon(
                    Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < playlists.length; i++)
                    _PlaylistRowTile(
                      playlist: playlists[i],
                      isLast: i == playlists.length - 1,
                    ),
                ],
              ),
            ),
            crossFadeState:
                expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 220),
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }
}

class _PlaylistRowTile extends StatelessWidget {
  const _PlaylistRowTile({required this.playlist, required this.isLast});

  final NeteaseUserPlaylist playlist;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 需求：歌单显示歌单封面（网易云样式：封面 46 + 名称 + 曲目数）；
    // 第十二批：封面带 Hero（与歌单详情页大图同 tag）
    final Widget row = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Hero(
          tag: playlistCoverHeroTag(playlist.id),
          child: CoverImage(
            src: playlist.coverUrl,
            size: 46,
            radius: 8,
          ),
        ),
      ),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14.5),
      ),
      subtitle: Text(
        '${playlist.trackCount}首',
        style:
            TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right_rounded,
          size: 18, color: theme.colorScheme.onSurfaceVariant),
      onTap: () => context.push(
        '/playlist/${playlist.id}?name=${Uri.encodeComponent(playlist.name)}',
        extra: PlaylistMeta(
          id: playlist.id,
          name: playlist.name,
          coverUrl: playlist.coverUrl,
          trackCount: playlist.trackCount,
          creatorUserId: playlist.creatorUserId,
        ),
      ),
    );
    if (isLast) return row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
            width: 0.6,
          ),
        ),
      ),
      child: row,
    );
  }
}

// ---------------------------------------------------------------- 数据缓存

/// 数据缓存行（需求：我的页增加数据缓存，展示占用并可清理，
/// 保障无网环境播放已缓存歌曲的体验）
class _CacheRow extends ConsumerStatefulWidget {
  const _CacheRow();

  @override
  ConsumerState<_CacheRow> createState() => _CacheRowState();
}

class _CacheRowState extends ConsumerState<_CacheRow> {
  String _sizeText = '计算中…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final int bytes = await ref.read(songCacheProvider).totalSizeBytes();
    if (!mounted) return;
    setState(() => _sizeText = _fmt(bytes));
  }

  static String _fmt(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          // 需求：点击数据缓存 → 查看缓存的音乐列表（清空入口在列表页内）
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
                builder: (BuildContext _) => const CacheSongsPage()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[Color(0xFFFFCC80), Color(0xFFEF6C00)],
                    ),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(Icons.storage_rounded,
                      size: 20, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('数据缓存',
                          style: TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 1),
                      Text('边听边缓存占用：$_sizeText，点击查看缓存音乐',
                          style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 19, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
