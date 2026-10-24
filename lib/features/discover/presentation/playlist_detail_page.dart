/// 歌单 / 排行榜详情页（对齐网易云 App 与 描述.txt）：
///
///  - 顶部：悬浮透明导航（返回 / 搜索 / 更多⋮）；
///  - Hero 封面区：大图 + 底部深色渐变蒙版；标题（心形）+ 创作者行
///    （头像 / 昵称 / VIP 皇冠 / 播放量）+ 三胶囊（分享 / 评论 / 收藏）；
///  - 控制区：红色大圆播放钮 + 播放全部 + 曲目数与总时长 + 右侧
///    筛选（VIP/免费）/ 下载全部 / 排序三个线框图标；
///  - 歌曲列表：封面缩略图 + 标题（VIP 标签）+ 歌手 - 专辑；当前播放行
///    右侧显示带光圈的动态播放图标；⋮ 打开歌曲操作菜单；
///  - 行手势：右滑删除出歌单（仅自己创建的歌单）；左滑添加至歌单；
///  - ⋮ 菜单：分享歌单 / 收藏或取消收藏 / 删除歌单（仅自己创建）。
library;

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/platform_actions.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/providers/auth_providers.dart';
import '../../comments/providers/comments_providers.dart' show CommentsSubject;
import '../../library/data/download_service.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/add_to_playlist_sheet.dart';
import '../../player/providers/cache_providers.dart';
import '../../player/providers/player_providers.dart';
import '../data/netease_providers.dart';
import 'widgets/song_actions_sheet.dart';
import 'widgets/song_tile.dart' show VipBadge;
import '../../../core/widgets/sheet_host.dart' show showMingSheet;

class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage._({
    required this.playlistId,
    this.meta,
    required this.title,
  });

  /// 歌单入口（meta 已有封面/名称，头部直接展示）
  factory PlaylistDetailPage.playlist({required PlaylistMeta meta}) =>
      PlaylistDetailPage._(playlistId: meta.id, meta: meta, title: meta.name);

  /// 排行榜入口（id 固定，名称静态配置）
  factory PlaylistDetailPage.toplist({required int id, required String name}) =>
      PlaylistDetailPage._(playlistId: id, title: name);

  final int playlistId;
  final PlaylistMeta? meta;
  final String title;

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  /// 需求「无网时也可在我的中点击歌单查看」：详情数据落盘
  /// （applicationSupport/playlist_cache/{id}.json），打开时缓存优先
  /// 立即渲染，有网后台刷新回写；无网/请求失败时展示离线快照。
  PlaylistDetail? _data;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _initialLoad();
  }

  Future<void> _initialLoad() async {
    final PlaylistDetail? cached = await _readDiskCache();
    if (!mounted) return;
    if (cached != null && cached.tracks.isNotEmpty) {
      setState(() => _data = cached);
    }
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final PlaylistDetail fresh = await ref
          .read(neteaseRepositoryProvider)
          .playlistDetail(widget.playlistId);
      unawaited(_writeDiskCache(fresh));
      if (!mounted) return;
      setState(() {
        _data = fresh;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // 已有离线快照时静默（离线场景）；无快照才显示错误页
      if (_data == null) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<PlaylistDetail?> _readDiskCache() async {
    try {
      final Directory dir = await _cacheDir();
      final File f = File('${dir.path}/${widget.playlistId}.json');
      if (!f.existsSync()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      return PlaylistDetail.fromStoredJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDiskCache(PlaylistDetail d) async {
    try {
      if (d.tracks.isEmpty) return;
      final Directory dir = await _cacheDir();
      final File f = File('${dir.path}/${widget.playlistId}.json');
      await f.writeAsString(jsonEncode(d.toJson()), flush: true);
    } catch (_) {}
  }

  Future<Directory> _cacheDir() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory('${support.path}/playlist_cache');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  @override
  Widget build(BuildContext context) {
    final PlaylistDetail? data = _data;
    if (data != null) {
      return Scaffold(
        body: _DetailBody(
          meta: data.meta,
          fallbackTitle: widget.title,
          tracks: data.tracks,
          isMine: _isMine(data.meta),
          loading: _loading,
          // 长按菜单「移除歌单」成功后刷新详情数据
          onReload: _refresh,
        ),
      );
    }
    if (_error != null) {
      return Scaffold(
        body: _ErrorPanel(onRetry: _refresh, message: _error),
      );
    }
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
      ),
    );
  }

  /// 是否为当前登录用户创建的歌单（删除/右滑移除歌曲仅对自有歌单开放）
  bool _isMine(PlaylistMeta meta) {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return false;
    final int? creatorId = meta.creatorUserId ?? widget.meta?.creatorUserId;
    return creatorId != null && creatorId == auth.profile?.userId;
  }
}

// ---------------------------------------------------------------- body

class _DetailBody extends ConsumerStatefulWidget {
  const _DetailBody({
    required this.meta,
    required this.fallbackTitle,
    required this.tracks,
    required this.isMine,
    required this.onReload,
    this.loading = false,
  });

  final PlaylistMeta meta;
  final String fallbackTitle;
  final List<Song> tracks;
  final bool isMine;

  /// 详情数据刷新（长按菜单移除歌曲后回调）
  final VoidCallback onReload;

  /// 离线快照已展示 + 后台刷新中（顶部细线进度提示）
  final bool loading;

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  /// 筛选：all / vip / free
  String _filter = 'all';

  /// 排序：default / name / artist / duration
  String _sort = 'default';

  bool _subscribed = false;
  bool _subBusy = false;
  bool _downloading = false;
  int _downloaded = 0;

  List<Song> get _visible {
    Iterable<Song> list = widget.tracks;
    if (_filter == 'vip') {
      list = list.where((Song s) => s.isVipOnly);
    } else if (_filter == 'free') {
      list = list.where((Song s) => !s.isVipOnly);
    }
    final List<Song> out = list.toList(growable: false);
    switch (_sort) {
      case 'name':
        out.sort((Song a, Song b) => a.name.compareTo(b.name));
      case 'artist':
        out.sort((Song a, Song b) => a.artists.compareTo(b.artists));
      case 'duration':
        out.sort((Song a, Song b) =>
            (b.durationMs ?? 0).compareTo(a.durationMs ?? 0));
    }
    return out;
  }

  String get _title => widget.meta.name;

  void _playAll(int indexInVisible) {
    final List<Song> visible = _visible;
    if (visible.isEmpty) return;
    ref.read(playerProvider.notifier).playSongs(
      <Track>[for (final Song s in visible) s.toTrack()],
      startIndex: indexInVisible,
      queueTitle: _title,
    );
  }

  String _totalDurationText() {
    final int ms = widget.tracks
        .fold<int>(0, (int acc, Song s) => acc + (s.durationMs ?? 0));
    if (ms <= 0) return '';
    final int minutes = ms ~/ 60000;
    if (minutes >= 60) {
      return '大于${minutes ~/ 60}小时';
    }
    return '$minutes分钟';
  }

  // ------------------------------------------------------------- actions

  Future<void> _toggleSubscribe() async {
    if (_subBusy) return;
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登录后即可收藏歌单')),
      );
      return;
    }
    setState(() => _subBusy = true);
    try {
      await ref
          .read(neteaseRepositoryProvider)
          .playlistSubscribe(widget.meta.id, subscribe: !_subscribed);
      if (!mounted) return;
      setState(() {
        _subscribed = !_subscribed;
        _subBusy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_subscribed ? '已收藏歌单' : '已取消收藏')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _subBusy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('操作失败：$e')));
    }
  }

  Future<void> _deletePlaylist() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定删除歌单「$_title」吗？该操作不可恢复。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(neteaseRepositoryProvider).playlistDelete(widget.meta.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('歌单已删除')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  Future<void> _downloadAll() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _downloaded = 0;
    });
    int okCount = 0;
    for (final Song s in widget.tracks) {
      if (!mounted) return;
      final DownloadResult r = await downloadTrack(ref, s.toTrack());
      if (r.ok) okCount++;
      if (mounted) setState(() => _downloaded++);
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              '下载完成：$okCount/${widget.tracks.length} 首，已保存到 Music/MingMusic')),
    );
  }

  void _showMoreMenu() {
    showMingSheet<void>(
      context,
      builder: (BuildContext ctx) => Container(
        decoration: const BoxDecoration(
          color: AppConstants.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 6),
              ListTile(
                leading: const Icon(Icons.share_rounded, size: 22),
                title: const Text('分享歌单', style: TextStyle(fontSize: 15)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await PlatformActions.shareText(
                    '$_title https://music.163.com/#/playlist?id=${widget.meta.id}',
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  _subscribed
                      ? Icons.bookmark_added_rounded
                      : Icons.bookmark_add_outlined,
                  size: 22,
                ),
                title: Text(
                  _subscribed ? '取消收藏歌单' : '收藏歌单',
                  style: const TextStyle(fontSize: 15),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _toggleSubscribe();
                },
              ),
              if (widget.isMine)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    size: 22,
                    color: AppConstants.brandColor,
                  ),
                  title: const Text(
                    '移除歌单',
                    style:
                        TextStyle(fontSize: 15, color: AppConstants.brandColor),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _deletePlaylist();
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  void _showFilterSheet() {
    showMingSheet<void>(
      context,
      builder: (BuildContext ctx) => Container(
        decoration: const BoxDecoration(
          color: AppConstants.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 12),
              const Text('筛选歌曲',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final (String, String) f in const <(String, String)>[
                ('all', '全部歌曲'),
                ('vip', '仅 VIP 歌曲'),
                ('free', '仅免费歌曲'),
              ])
                ListTile(
                  title: Text(f.$2, style: const TextStyle(fontSize: 15)),
                  trailing: _filter == f.$1
                      ? const Icon(Icons.check_rounded,
                          color: AppConstants.brandColor, size: 20)
                      : null,
                  onTap: () {
                    setState(() => _filter = f.$1);
                    Navigator.of(ctx).pop();
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  void _showSortSheet() {
    showMingSheet<void>(
      context,
      builder: (BuildContext ctx) => Container(
        decoration: const BoxDecoration(
          color: AppConstants.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 12),
              const Text('排序方式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final (String, String) f in const <(String, String)>[
                ('default', '默认排序'),
                ('name', '按歌名'),
                ('artist', '按歌手'),
                ('duration', '按时长'),
              ])
                ListTile(
                  title: Text(f.$2, style: const TextStyle(fontSize: 15)),
                  trailing: _sort == f.$1
                      ? const Icon(Icons.check_rounded,
                          color: AppConstants.brandColor, size: 20)
                      : null,
                  onTap: () {
                    setState(() => _sort = f.$1);
                    Navigator.of(ctx).pop();
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final double coverH = MediaQuery.sizeOf(context).height * 0.5;
    final String playCountText = _playCountText(widget.meta.playCount);
    final String subtitle = <String>[
      '${widget.tracks.length}首',
      if (_totalDurationText().isNotEmpty) _totalDurationText(),
    ].join(' · ');
    final int currentId = ref.watch(playerProvider
        .select((PlayerState s) => s.currentTrack?.neteaseId ?? 0));

    return CustomScrollView(
      slivers: <Widget>[
        // 离线快照后台刷新中：顶部细线进度提示
        if (widget.loading)
          const SliverToBoxAdapter(
            child: LinearProgressIndicator(minHeight: 2),
          ),
        // ---------- 顶部悬浮导航（透明，覆盖在封面上） ----------
        SliverAppBar(
          pinned: true,
          backgroundColor: AppConstants.darkScaffold,
          expandedHeight: coverH,
          toolbarHeight: 56,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded,
                size: 24, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          actions: <Widget>[
            IconButton(
              tooltip: '搜索页内歌曲',
              icon: const Icon(Icons.search_rounded,
                  size: 23, color: Colors.white),
              onPressed: () => context.push('/search'),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert_rounded,
                  size: 24, color: Colors.white),
              onPressed: _showMoreMenu,
            ),
          ],
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            _title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w600,
                color: Colors.white),
          ),
          flexibleSpace: _CoverHero(
            meta: widget.meta,
            title: _title,
            playCountText: playCountText,
            playCount: widget.meta.playCount ?? 0,
            commentCount: widget.meta.commentCount ?? 0,
            subscribed: _subscribed,
            subBusy: _subBusy,
            onShare: () => PlatformActions.shareText(
              '$_title https://music.163.com/#/playlist?id=${widget.meta.id}',
            ),
            onComment: () => context.push(
              '/comments',
              extra: CommentsSubject(
                id: widget.meta.id,
                subjectType: '2',
                title: '歌单：$_title',
              ),
            ),
            onSubscribe: _toggleSubscribe,
          ),
        ),
        // ---------- 控制区 ----------
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Material(
                    color: AppConstants.brandColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: widget.tracks.isEmpty ? null : () => _playAll(0),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 5),
                        child: Row(
                          children: <Widget>[
                            CircleAvatar(
                              radius: 17,
                              backgroundColor: AppConstants.brandColor,
                              child: const Icon(Icons.play_arrow_rounded,
                                  color: Colors.white, size: 24),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '播放全部',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white),
                                  ),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _BarIcon(
                  icon: Icons.filter_alt_outlined,
                  tooltip: '筛选',
                  onTap: _showFilterSheet,
                ),
                _BarIcon(
                  icon: Icons.download_outlined,
                  tooltip: '下载全部',
                  busy: _downloading,
                  progress: _downloading && widget.tracks.isNotEmpty
                      ? _downloaded / widget.tracks.length
                      : null,
                  onTap: widget.tracks.isEmpty ? null : _downloadAll,
                ),
                _BarIcon(
                  icon: Icons.swap_vert_rounded,
                  tooltip: '排序',
                  onTap: _showSortSheet,
                ),
              ],
            ),
          ),
        ),
        if (_downloading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(
                value: widget.tracks.isEmpty
                    ? null
                    : _downloaded / widget.tracks.length,
                minHeight: 2,
                backgroundColor: Colors.white10,
                color: AppConstants.brandColor,
              ),
            ),
          ),
        // ---------- 歌曲列表 ----------
        if (widget.tracks.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('该歌单暂无曲目')),
          )
        else
          SliverList.builder(
            itemCount: _visible.length,
            itemBuilder: (BuildContext context, int index) {
              final Song s = _visible[index];
              final bool playingNow = currentId == s.id;
              return _SwipeSongRow(
                key: ValueKey<int>(s.id),
                song: s,
                index: index,
                playingNow: playingNow,
                onPlay: () => _playAll(index),
                onMore: () => showSongActionsSheet(
                  context,
                  s.toTrack(),
                  playlistId: widget.meta.id,
                  onRemoved: widget.onReload,
                ),
                onLongPress: () => showSongActionsSheet(
                  context,
                  s.toTrack(),
                  playlistId: widget.meta.id,
                  onRemoved: widget.onReload,
                ),
                onAddTo: () =>
                    showAddToPlaylistSheet(context, ref, <int>[s.id]),
                // 需求：左滑 = 添加至下一首播放（不打断播放，增量插入）
                onAddNext: () async {
                  final String? err = await ref
                      .read(playerProvider.notifier)
                      .insertNext(s.toTrack());
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(err ?? '已添加至下一首播放：${s.name}'),
                  ));
                },
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  static String _playCountText(int? c) {
    if (c == null || c <= 0) return '';
    if (c >= 100000000) return '${(c / 100000000).toStringAsFixed(1)}亿';
    if (c >= 10000) return '${(c / 10000).toStringAsFixed(0)}万';
    return '$c';
  }
}

// ---------------------------------------------------------------- Hero 封面区

class _CoverHero extends StatelessWidget {
  const _CoverHero({
    required this.meta,
    required this.title,
    required this.playCountText,
    required this.playCount,
    required this.commentCount,
    required this.subscribed,
    required this.subBusy,
    required this.onShare,
    required this.onComment,
    required this.onSubscribe,
  });

  final PlaylistMeta meta;
  final String title;
  final String playCountText;
  final int playCount;
  final int commentCount;
  final bool subscribed;
  final bool subBusy;
  final VoidCallback onShare;
  final VoidCallback onComment;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    return FlexibleSpaceBar(
      background: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 大封面 + 底部深蓝渐变蒙版（描述：向下自然过渡）；
          // 第十二批需求：Hero 歌单封面 —— 与「我的」页宫格卡/列表行同 tag，
          // 点击封面进入详情页时封面从小卡平滑放大成全屏大图
          if (meta.id > 0)
            Hero(
              tag: playlistCoverHeroTag(meta.id),
              child: CoverImage(
                src: meta.coverUrl,
                size: 600,
                radius: 0,
                coverSize: CoverSize.original,
              ),
            )
          else
            CoverImage(
              src: meta.coverUrl,
              size: 600,
              radius: 0,
              coverSize: CoverSize.original,
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: <double>[0.30, 0.62, 1.0],
                colors: <Color>[
                  Colors.transparent,
                  Color(0x880D1B3A),
                  Color(0xFF0D1B3A),
                ],
              ),
            ),
          ),
          // 信息区：标题（心形）+ 创作者行 + 三胶囊
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.favorite_rounded,
                          color: Colors.white, size: 19),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: Colors.white24,
                        backgroundImage: (meta.creatorAvatarUrl != null &&
                                meta.creatorAvatarUrl!.startsWith('http'))
                            // 网易 CDN 对 Dart 默认 UA 返回 403（实测取证）——
                            // 裸 NetworkImage 必须显式携带浏览器 UA（全库统一）
                            ? NetworkImage(
                                meta.creatorAvatarUrl!,
                                headers: const <String, String>{
                                  'User-Agent': CoverImage.kImageUserAgent,
                                },
                              )
                            : null,
                        child: (meta.creatorAvatarUrl == null ||
                                !meta.creatorAvatarUrl!.startsWith('http'))
                            ? const Icon(Icons.person_rounded,
                                size: 14, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          meta.creator ?? '未知创作者',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.86),
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // VIP 皇冠（创作者身份标识，紫金小皇冠）
                      const _CrownBadge(),
                      const Spacer(),
                      if (playCountText.isNotEmpty)
                        Text(
                          '$playCountText次播放',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 11.5,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // 互动胶囊组：分享 / 评论 / 收藏
                  Row(
                    children: <Widget>[
                      _HeroPill(
                        icon: Icons.share_rounded,
                        label: playCount > 0 ? '分享' : '分享',
                        onTap: onShare,
                      ),
                      const SizedBox(width: 10),
                      _HeroPill(
                        icon: Icons.mode_comment_outlined,
                        label: commentCount > 0
                            ? _formatCount(commentCount)
                            : '评论',
                        onTap: onComment,
                      ),
                      const SizedBox(width: 10),
                      _HeroPill(
                        icon: subscribed
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_add_outlined,
                        label: subscribed ? '已收藏' : '收藏',
                        busy: subBusy,
                        onTap: onSubscribe,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ).animate(delay: 60.ms).fadeIn(duration: 300.ms).slideY(
                begin: 0.10,
                end: 0,
                curve: Curves.easeOutCubic,
                duration: 340.ms,
              ),
        ],
      ),
    );
  }

  static String _formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(0)}亿+';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(0)}万+';
    return '$n';
  }
}

/// 创作者 VIP 小皇冠（紫金渐变）
class _CrownBadge extends StatelessWidget {
  const _CrownBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: <Color>[Color(0xFFB8873B), Color(0xFFE8B45C)]),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(Icons.workspace_premium_rounded,
          size: 11, color: Colors.white),
    );
  }
}

/// 封面区胶囊按钮（半透明深色）
class _HeroPill extends StatelessWidget {
  const _HeroPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: Colors.white),
                    )
                  : Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 控制区图标

class _BarIcon extends StatelessWidget {
  const _BarIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
    this.progress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool busy;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    Widget child = Icon(
      icon,
      size: 21,
      color: onTap == null
          ? Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.4)
          : Theme.of(context).colorScheme.onSurfaceVariant,
    );
    if (busy) {
      child = SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: progress,
          color: AppConstants.brandColor,
        ),
      );
    }
    return SizedBox(
      width: 40,
      height: 40,
      child: Tooltip(
        message: tooltip,
        triggerMode: TooltipTriggerMode.longPress,
        child: IconButton(
          padding: EdgeInsets.zero,
          onPressed: onTap,
          icon: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 歌曲行

/// 歌单歌曲行（封面缩略图 + 标题 + VIP 标签 + 歌手-专辑），
/// 需求调整：左滑添加至歌单 / 右滑下一首播放（移除改由长按菜单承载）；
/// 仅无网且未缓存时整行暗淡（有网一律正常）。
class _SwipeSongRow extends ConsumerWidget {
  const _SwipeSongRow({
    super.key,
    required this.song,
    required this.index,
    required this.playingNow,
    required this.onPlay,
    required this.onMore,
    required this.onAddTo,
    required this.onAddNext,
    this.onLongPress,
  });

  final Song song;
  final int index;
  final bool playingNow;
  final VoidCallback onPlay;
  final VoidCallback onMore;

  /// 左滑：添加至歌单
  final VoidCallback onAddTo;

  /// 右滑 = 添加至下一首播放
  final Future<void> Function() onAddNext;

  /// 需求：所有歌曲长按弹出统一操作菜单
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // 需求修正：暗淡仅发生在「无网且未缓存」—— 有网时歌曲一律正常
    // 显示；无网时未缓存歌曲整行暗淡（歌名/歌手/VIP/封面 同规则
    // alpha 0.38；已缓存或正在播放正常显示）
    final Set<int> cachedIds =
        ref.watch(cachedSongIdsProvider).valueOrNull ?? const <int>{};
    final bool online = ref.watch(networkAvailableProvider
        .select((AsyncValue<bool> v) => v.valueOrNull ?? true));
    final bool cached = cachedIds.contains(song.id);
    final bool normal = playingNow || cached || online;
    final Color titleColor = playingNow
        ? AppConstants.brandColor
        : normal
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final Color subtitleColor = normal
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38);

    final Widget row = InkWell(
      onTap: onPlay,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          children: <Widget>[
            // 封面缩略图（方形圆角小图）
            Opacity(
              opacity: normal ? 1 : 0.38,
              child: CoverImage(src: song.coverUrl, size: 48, radius: 6),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (song.isVipOnly) ...<Widget>[
                        // 未缓存 VIP 同步暗淡
                        const SizedBox(width: 6),
                        Opacity(
                          opacity: normal ? 1 : 0.38,
                          child: const VipBadge(),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.album.isEmpty
                        ? song.artists
                        : '${song.artists} - ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 当前播放：带光圈的动态播放图标；其余行：⋮
            if (playingNow)
              const _PlayingBadge()
            else
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.more_vert_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: onMore,
              ),
          ],
        ),
      ),
    );

    // 需求调整：滑动方向对调 —— 左滑 = 添加至歌单；右滑 = 下一首播放。
    // （旧「右滑移除」已移除，移除仍可在长按菜单中使用，不真正滑走）
    final Widget swipeable = Dismissible(
      key: ValueKey<String>('row_${song.id}_$index'),
      confirmDismiss: (DismissDirection dir) async {
        if (dir == DismissDirection.startToEnd) {
          await onAddNext(); // 右滑：下一首播放
        } else {
          onAddTo(); // 左滑：添加至歌单
        }
        return false; // 动作完成后回弹，不移除行
      },
      background: _SwipeBg(
        color: AppConstants.brandColor,
        icon: Icons.low_priority_rounded,
        label: '下一首播放',
        alignRight: false,
      ),
      secondaryBackground: _SwipeBg(
        color: const Color(0xFF3D7BFF),
        icon: Icons.playlist_add_rounded,
        label: '添加到歌单',
        alignRight: true,
      ),
      child: row,
    );

    return swipeable;
  }
}

/// 当前播放标识：光圈 + 跳动播放图标
class _PlayingBadge extends StatefulWidget {
  const _PlayingBadge();

  @override
  State<_PlayingBadge> createState() => _PlayingBadgeState();
}

class _PlayingBadgeState extends State<_PlayingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (BuildContext ctx, Widget? _) {
        final double glow = 0.35 + 0.45 * _ctrl.value;
        return Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppConstants.brandColor.withValues(alpha: glow),
              width: 1.6,
            ),
          ),
          child: const Icon(Icons.graphic_eq_rounded,
              size: 15, color: AppConstants.brandColor),
        );
      },
    );
  }
}

/// 滑动背景
class _SwipeBg extends StatelessWidget {
  const _SwipeBg({
    required this.color,
    required this.icon,
    required this.label,
    required this.alignRight,
  });

  final Color color;
  final IconData icon;
  final String label;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (alignRight) ...<Widget>[
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
          ],
          Icon(icon, color: Colors.white, size: 20),
          if (!alignRight) ...<Widget>[
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 错误面板

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.onRetry, this.message});

  final VoidCallback onRetry;

  /// 具体错误文案（离线快照不存在时的首载失败）
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.cloud_off_rounded,
              size: 44, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(message == null ? '加载失败，请检查网络' : '加载失败：$message',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
