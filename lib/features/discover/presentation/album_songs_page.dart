/// 专辑歌曲页（/album）：封面头部 + 曲目列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../../social/presentation/share_to_friend_sheet.dart'
    show showShareToFriendSheet;
import '../data/netease_providers.dart';
import 'widgets/song_actions_sheet.dart';
import 'widgets/song_tile.dart';

class AlbumSongsPage extends ConsumerStatefulWidget {
  const AlbumSongsPage({super.key, required this.albumId, required this.name});

  final int albumId;
  final String name;

  @override
  ConsumerState<AlbumSongsPage> createState() => _AlbumSongsPageState();
}

class _AlbumSongsPageState extends ConsumerState<AlbumSongsPage> {
  late Future<AlbumDetail> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(neteaseRepositoryProvider).albumDetail(widget.albumId);
  }

  void _reload() {
    setState(() {
      _future = ref.read(neteaseRepositoryProvider).albumDetail(widget.albumId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<AlbumDetail>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<AlbumDetail> snap) {
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
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Text('专辑加载失败'),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            );
          }
          final AlbumDetail detail = snap.data!;
          return _AlbumBody(detail: detail);
        },
      ),
    );
  }
}

class _AlbumBody extends ConsumerWidget {
  const _AlbumBody({required this.detail});

  final AlbumDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Song> tracks = detail.tracks;
    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          backgroundColor: AppConstants.darkScaffold,
          title: Text(
            detail.meta.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Hero(
                  tag: 'album-cover-${detail.meta.id}',
                  child: CoverImage(
                    src: detail.meta.coverUrl,
                    size: 110,
                    radius: 10,
                    coverSize: CoverSize.large,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        detail.meta.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        <String>[
                          if (detail.meta.creator != null) detail.meta.creator!,
                          '${tracks.length} 首',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 17,
                  backgroundColor: AppConstants.brandColor,
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 10),
                Text('播放全部 (${tracks.length})',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const Spacer(),
                // 需求（第二十九批）：私信分享专辑
                //（POST /send/album，文档「发送私信(带专辑)」接入）
                TextButton.icon(
                  onPressed: () => showShareToFriendSheet(context, ref,
                      kind: 'album',
                      id: detail.meta.id,
                      name: detail.meta.name),
                  icon: const Icon(Icons.mail_outline_rounded, size: 17),
                  label: const Text('私信分享', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppConstants.brandColor,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('专辑暂无曲目')),
            ),
          )
        else
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (BuildContext context, int index) {
              final Song s = tracks[index];
              return SongTile(
                song: s,
                trackIndex: index + 1,
                onPlay: () => ref.read(playerProvider.notifier).playSongs(
                  <Track>[
                    for (final Song x in tracks) x.toTrack(),
                  ],
                  startIndex: index,
                  queueTitle: '专辑：${detail.meta.name}',
                ),
                onMore: () => showSongActionsSheet(context, s.toTrack()),
                onLongPress: () => showSongActionsSheet(context, s.toTrack()),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        // 第十六批需求：底部留出冗余，防 Mini 条遮挡末尾行无法交互
        SliverPadding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 96),
        ),
      ],
    );
  }
}
