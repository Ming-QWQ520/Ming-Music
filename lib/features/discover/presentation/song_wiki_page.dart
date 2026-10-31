/// 歌曲百科页（仿网易云「歌曲百科」，聚合多 API 闭环）：
///  - 顶部：歌名 / 歌手 / 本机总听次数（playStats 持久化统计）；
///  - 音乐百科（/song/wiki/summary）：曲风 / 推荐标签 / 获奖成就 / 影视节目 / 乐评；
///  - 艺人卡（/artist/detail）：身份描述 + 作品规模，点击进艺人热门歌曲页；
///  - MV 卡（song.mv + /mv/detail）：封面 + 播放量，点击进 MV 播放页；
///  - 热评卡（/comment/new sortType=2）：评论总数 + 首条热评，点击进评论页；
///  - 相似歌曲（/simi/song）：点击插播到当前歌曲下一首；
///  - 相关歌单（/simi/playlist）：点击进歌单详情页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../comments/presentation/comments_page.dart';
import '../../comments/providers/comments_providers.dart';
import '../../comments/data/comments_repository.dart'
    show CommentItem, CommentPage;
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../data/netease_providers.dart' show neteaseRepositoryProvider;
import 'mv_player_page.dart';

import '../../../core/widgets/app_notify.dart';

class SongWikiPage extends ConsumerWidget {
  const SongWikiPage({
    super.key,
    required this.songId,
    required this.title,
    required this.artist,
    this.mvId,
  });

  final int songId;
  final String title;
  final String artist;
  final int? mvId;

  /// 万/亿格式化（对齐 Zephyr formatCount）
  static String formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppConstants.darkScaffold,
      appBar: AppBar(
        title: const Text('歌曲百科',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          // 歌曲头（需求：去除本机听歌次数及其功能）
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800, height: 1.25)),
              const SizedBox(height: 4),
              Text(artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14, color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 16),

          // MV 卡（有 MV 才显示；闭环：详情 + 直链 + 播放页）
          if (mvId != null) ...<Widget>[
            _MvCard(mvId: mvId!, fallbackTitle: title),
            const SizedBox(height: 12),
          ],

          // 回忆坐标（服务端数据：首次聆听 + 累计播放）。
          // 需求：回忆坐标位置调整 —— 移到音乐百科上方（先回忆坐标、后百科）
          _WikiSection(
            songId: songId,
            builder: (SongWikiSummary wiki) {
              final bool hasFirst = wiki.firstListenDate.isNotEmpty ||
                  wiki.firstListenDesc.isNotEmpty;
              if (!hasFirst && wiki.totalPlayCount == 0) {
                return const SizedBox.shrink();
              }
              return _SectionCard(
                title: '回忆坐标',
                child: Column(
                  children: <Widget>[
                    if (hasFirst)
                      _MemoryCell(
                        label: '首次聆听',
                        main: wiki.firstListenDate.isEmpty
                            ? '—'
                            : wiki.firstListenDate,
                        sub: wiki.firstListenExtra,
                        extra: wiki.firstListenDesc,
                      ),
                    if (wiki.totalPlayCount > 0) ...<Widget>[
                      if (hasFirst) const SizedBox(height: 10),
                      _MemoryCell(
                        label: '累计播放',
                        main: '${formatCount(wiki.totalPlayCount)} 次',
                        sub: wiki.totalPlayText,
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),

          // 音乐百科块（曲风/推荐标签/获奖成就/影视节目/乐评）
          _WikiSection(
            songId: songId,
            builder: (SongWikiSummary wiki) {
              if (wiki.groups.isEmpty) return const SizedBox.shrink();
              return _SectionCard(
                title: '音乐百科',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final WikiGroup g in wiki.groups) ...<Widget>[
                      _WikiGroupRow(group: g),
                      if (g != wiki.groups.last) const SizedBox(height: 10),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),

          // 艺人卡
          _ArtistCard(artistName: artist.split(' / ').first),
          const SizedBox(height: 12),

          // 热评卡
          _HotCommentCard(songId: songId, title: title),
          const SizedBox(height: 12),

          // 相似歌曲
          _SimiSongsCard(songId: songId),
          const SizedBox(height: 12),

          // 相关歌单
          _SimiPlaylistsCard(songId: songId),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 回忆坐标单元

/// 回忆坐标卡片内的单元格（首次聆听 / 累计播放）
class _MemoryCell extends StatelessWidget {
  const _MemoryCell({
    required this.label,
    required this.main,
    required this.sub,
    this.extra,
  });

  final String label;
  final String main;
  final String sub;

  /// 补充描述（musicFirstListenDto.desc，需求「首次聆听显示补全」）
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          // 需求「首次聆听显示补全」：主值不再单行截断（日期+时段可能较长），
          // 允许自动换行完整展示；desc 补充描述（超越百分比等）补全显示
          Text(main,
              style: const TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w800,
                  color: AppConstants.brandColor,
                  height: 1.3)),
          if (sub.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(sub,
                style: TextStyle(
                    fontSize: 10.5,
                    height: 1.3,
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (extra != null && extra!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(extra!,
                style: TextStyle(
                    fontSize: 10.5,
                    height: 1.3,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.8))),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 通用卡

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.onMore});

  final String title;
  final Widget child;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
              ),
              if (onMore != null)
                GestureDetector(
                  onTap: onMore,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('全部',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant)),
                      Icon(Icons.chevron_right_rounded,
                          size: 16, color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- MV 卡

class _MvCard extends ConsumerWidget {
  const _MvCard({required this.mvId, required this.fallbackTitle});

  final int mvId;
  final String fallbackTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<MvDetail> async = ref.watch(mvDetailProvider(mvId));

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () =>
            openMvPlayer(context, mvId: mvId, fallbackTitle: fallbackTitle),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Stack(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CoverImage(
                      src: async.valueOrNull?.coverUrl,
                      size: 92,
                      radius: 10,
                    ),
                  ),
                  const Positioned.fill(
                    child: Center(
                      child: Icon(Icons.play_circle_fill_rounded,
                          color: Colors.white70, size: 30),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Row(
                      children: <Widget>[
                        Icon(Icons.ondemand_video_rounded,
                            size: 16, color: AppConstants.brandColor),
                        SizedBox(width: 5),
                        Text('MV',
                            style: TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      async.valueOrNull?.name ?? fallbackTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      async.valueOrNull == null
                          ? '加载中…'
                          : '${_formatCount(async.value!.playCount)}次播放 · 点击观看',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

// ---------------------------------------------------------------- 百科块

final FutureProviderFamily<SongWikiSummary, int> _wikiProvider =
    FutureProvider.family<SongWikiSummary, int>((Ref ref, int songId) {
  return ref.read(neteaseRepositoryProvider).songWiki(songId);
});

/// MV 详情（百科 MV 卡）
final FutureProviderFamily<MvDetail, int> mvDetailProvider =
    FutureProvider.family<MvDetail, int>((Ref ref, int mvId) {
  return ref.read(neteaseRepositoryProvider).mvDetail(mvId);
});

class _WikiSection extends ConsumerWidget {
  const _WikiSection({required this.songId, required this.builder});

  final int songId;
  final Widget Function(SongWikiSummary) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<SongWikiSummary> async = ref.watch(_wikiProvider(songId));
    return builder(async.valueOrNull ?? const SongWikiSummary());
  }
}

class _WikiGroupRow extends StatelessWidget {
  const _WikiGroupRow({required this.group});

  final WikiGroup group;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 66,
          child: Text(group.title,
              style: TextStyle(
                  fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String item in group.items)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(item, style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 艺人卡

class _ArtistCard extends ConsumerStatefulWidget {
  const _ArtistCard({required this.artistName});

  final String artistName;

  @override
  ConsumerState<_ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends ConsumerState<_ArtistCard> {
  Future<ArtistDetailInfo?>? _future;

  @override
  void initState() {
    super.initState();
    _future = _resolve();
  }

  Future<ArtistDetailInfo?> _resolve() async {
    final repo = ref.read(neteaseRepositoryProvider);
    // 歌手名搜索 → 首位艺人 → 详情（闭环：搜索→详情→艺人歌曲页）
    final int? id = await repo.artistIdByName(widget.artistName);
    if (id == null) return null;
    return repo.artistDetail(id);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FutureBuilder<ArtistDetailInfo?>(
      future: _future,
      builder: (BuildContext ctx, AsyncSnapshot<ArtistDetailInfo?> snap) {
        final ArtistDetailInfo? info = snap.data;
        if (info == null) return const SizedBox.shrink();
        return _SectionCard(
          title: '艺人',
          onMore: () => context.push(
              '/artist/${info.id}?name=${Uri.encodeComponent(info.name)}'),
          child: Row(
            children: <Widget>[
              ClipOval(
                child: CoverImage(src: info.coverUrl, size: 48, radius: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(info.name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    if (info.identityDesc.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(info.identityDesc,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${info.musicSize}首 · ${info.albumSize}专辑',
                style: TextStyle(
                    fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 热评卡

class _HotCommentCard extends ConsumerStatefulWidget {
  const _HotCommentCard({required this.songId, required this.title});

  final int songId;
  final String title;

  @override
  ConsumerState<_HotCommentCard> createState() => _HotCommentCardState();
}

class _HotCommentCardState extends ConsumerState<_HotCommentCard> {
  Future<CommentItem?>? _future;

  @override
  void initState() {
    super.initState();
    _future = ref
        .read(commentsRepositoryProvider)
        .fetchComments(widget.songId, sortType: 2, pageNo: 1, pageSize: 1)
        .then((CommentPage page) =>
            page.comments.isEmpty ? null : page.comments.first)
        .catchError((Object _) => null);
  }

  void _openComments() {
    // 构造最小 Track 以复用评论页入口
    showCommentsPage(
      context,
      Track(
        id: 'netease_${widget.songId}',
        neteaseId: widget.songId,
        title: widget.title,
        artist: '',
        album: '',
        source: '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int count =
        ref.watch(songCommentCountProvider(widget.songId)).value ?? 0;

    return FutureBuilder<CommentItem?>(
      future: _future,
      builder: (BuildContext ctx, AsyncSnapshot<CommentItem?> snap) {
        final CommentItem? hot = snap.data;
        return _SectionCard(
          title: '评论 (${_formatCount(count)})',
          onMore: _openComments,
          child: hot == null
              ? Text('暂无热评',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurfaceVariant))
              : Text(
                  hot.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.85)),
                ),
        );
      },
    );
  }

  static String _formatCount(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(0)}万+';
    return '$n';
  }
}

// ---------------------------------------------------------------- 相似歌曲

class _SimiSongsCard extends ConsumerStatefulWidget {
  const _SimiSongsCard({required this.songId});

  final int songId;

  @override
  ConsumerState<_SimiSongsCard> createState() => _SimiSongsCardState();
}

class _SimiSongsCardState extends ConsumerState<_SimiSongsCard> {
  Future<List<Song>>? _future;
  final Set<int> _busy = <int>{};

  @override
  void initState() {
    super.initState();
    _future = ref
        .read(neteaseRepositoryProvider)
        .simiSongs(widget.songId)
        .then((List<Song> list) => list.take(5).toList(growable: false));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FutureBuilder<List<Song>>(
      future: _future,
      builder: (BuildContext ctx, AsyncSnapshot<List<Song>> snap) {
        final List<Song> songs = snap.data ?? const <Song>[];
        if (songs.isEmpty) return const SizedBox.shrink();
        return _SectionCard(
          title: '相似歌曲',
          child: Column(
            children: <Widget>[
              for (final Song s in songs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: CoverImage(src: s.coverUrl, size: 40, radius: 6),
                  title: Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14)),
                  subtitle: Text(s.artists,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurfaceVariant)),
                  trailing: _busy.contains(s.id)
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.play_circle_outline_rounded,
                          size: 22, color: theme.colorScheme.onSurfaceVariant),
                  onTap: () => _play(s),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _play(Song song) async {
    if (_busy.contains(song.id)) return;
    setState(() => _busy.add(song.id));
    final String? error =
        await ref.read(playerProvider.notifier).playSimilarNext(song.toTrack());
    if (!mounted) return;
    setState(() => _busy.remove(song.id));
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      AppNotify.show(error);
    }
  }
}

// ---------------------------------------------------------------- 相关歌单

class _SimiPlaylistsCard extends ConsumerStatefulWidget {
  const _SimiPlaylistsCard({required this.songId});

  final int songId;

  @override
  ConsumerState<_SimiPlaylistsCard> createState() => _SimiPlaylistsCardState();
}

class _SimiPlaylistsCardState extends ConsumerState<_SimiPlaylistsCard> {
  late final Future<List<PlaylistMeta>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref
        .read(neteaseRepositoryProvider)
        .simiPlaylists(widget.songId)
        .then(
            (List<PlaylistMeta> list) => list.take(6).toList(growable: false));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PlaylistMeta>>(
      future: _future,
      builder: (BuildContext ctx, AsyncSnapshot<List<PlaylistMeta>> snap) {
        final List<PlaylistMeta> list = snap.data ?? const <PlaylistMeta>[];
        if (list.isEmpty) return const SizedBox.shrink();
        return _SectionCard(
          title: '相关歌单',
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.78,
            ),
            itemCount: list.length,
            itemBuilder: (BuildContext ctx, int index) {
              final PlaylistMeta p = list[index];
              return GestureDetector(
                onTap: () => context.push(
                  '/playlist/${p.id}?name=${Uri.encodeComponent(p.name)}',
                  extra: p,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: CoverImage(src: p.coverUrl, size: 120, radius: 10),
                    ),
                    const SizedBox(height: 5),
                    Text(p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, height: 1.25)),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
