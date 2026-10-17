/// 歌单 / 排行榜详情页：纯文字头部（无封面）+ 播放全部 + 序号歌曲列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../data/netease_providers.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import 'widgets/song_tile.dart';

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
  late Future<PlaylistDetail> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<PlaylistDetail> _load() =>
      ref.read(neteaseRepositoryProvider).playlistDetail(widget.playlistId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<PlaylistDetail>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<PlaylistDetail> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
            );
          }
          if (snap.hasError || !snap.hasData) {
            return _ErrorPanel(onRetry: () {
              setState(() => _future = _load());
            });
          }
          return _DetailBody(
            meta: snap.data!.meta,
            title: widget.title,
            tracks: snap.data!.tracks,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- body

class _DetailBody extends ConsumerWidget {
  const _DetailBody({
    required this.meta,
    required this.title,
    required this.tracks,
  });

  final PlaylistMeta? meta;
  final String title;
  final List<Song> tracks;

  void _playAll(WidgetRef ref, int startIndex) {
    if (tracks.isEmpty) return;
    final List<Track> list =
        tracks.map((Song s) => s.toTrack()).toList(growable: false);
    // VIP 灰曲自动跳过逻辑在 playSongs 内处理
    ref.read(playerProvider.notifier).playSongs(
          list,
          startIndex: startIndex,
          queueTitle: title,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 需求：歌单详情页不显示歌单封面 —— 头部为纯文字信息
    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          backgroundColor: AppConstants.darkScaffold,
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        SliverToBoxAdapter(
          child: _HeaderCard(meta: meta, count: tracks.length),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppConstants.brandColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    onPressed: tracks.isEmpty ? null : () => _playAll(ref, 0),
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                    label: Text(
                      '播放全部 (${tracks.length})',
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('该歌单暂无曲目')),
          )
        else
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (BuildContext context, int index) => SongTile(
              song: tracks[index],
              trackIndex: index + 1,
              onPlay: () => _playAll(ref, index),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.meta, required this.count});

  final PlaylistMeta? meta;
  final int count;

  String _playCountText() {
    final int? c = meta?.playCount;
    if (c == null) return '';
    if (c >= 100000000) return '${(c / 100000000).toStringAsFixed(1)}亿';
    if (c >= 10000) return '${(c / 10000).toStringAsFixed(0)}万';
    return '$c';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // 无封面头部：名称 + 统计信息（需求）
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  meta?.name ?? '排行榜',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700, height: 1.3),
                ),
                const SizedBox(height: 6),
                Text(
                  <String>[
                    if ((meta?.playCount ?? 0) > 0) '播放 ${_playCountText()} 次',
                    '$count 首',
                    if (meta?.creator != null) 'by ${meta!.creator}',
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.cloud_off_rounded,
              size: 44, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          const Text('加载失败，请检查网络'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
