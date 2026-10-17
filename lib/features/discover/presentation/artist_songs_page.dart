/// 艺人热门歌曲页（/artist/top/song，百科艺人卡的闭环延伸）：
///  - 顶部艺人头像 + 名称 + 作品规模；
///  - 歌曲列表点击即插播（对齐相似歌曲交互：加入当前歌曲下一首并切播）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../data/netease_providers.dart' show neteaseRepositoryProvider;

class ArtistSongsPage extends ConsumerStatefulWidget {
  const ArtistSongsPage({
    super.key,
    required this.artistId,
    required this.artistName,
  });

  final int artistId;
  final String artistName;

  @override
  ConsumerState<ArtistSongsPage> createState() => _ArtistSongsPageState();
}

class _ArtistSongsPageState extends ConsumerState<ArtistSongsPage> {
  late final Future<List<Song>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref
        .read(neteaseRepositoryProvider)
        .artistTopSongs(widget.artistId);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppConstants.darkScaffold,
      appBar: AppBar(
        title: Text(widget.artistName,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: FutureBuilder<List<Song>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<Song>> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2.2, color: AppConstants.brandColor),
            );
          }
          final List<Song> songs = snap.data ?? const <Song>[];
          if (songs.isEmpty) {
            return Center(
              child: Text('暂无热门歌曲',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: songs.length,
            itemBuilder: (BuildContext ctx, int index) {
              final Song s = songs[index];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Stack(
                  alignment: Alignment.centerLeft,
                  children: <Widget>[
                    if (index < 3)
                      SizedBox(
                        width: 22,
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w800,
                            color: AppConstants.brandColor
                                .withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.only(left: index < 3 ? 26.0 : 0),
                      child: CoverImage(src: s.coverUrl, size: 44, radius: 7),
                    ),
                  ],
                ),
                title: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    if (s.mvId != null && s.mvId! > 0) ...<Widget>[
                      const SizedBox(width: 5),
                      Icon(Icons.ondemand_video_rounded,
                          size: 14, color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ],
                ),
                subtitle: Text(
                  s.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: s.isVipOnly
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppConstants.brandColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text('VIP',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w800)),
                      )
                    : null,
                onTap: () => _play(s),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _play(Song song) async {
    final notifier = ref.read(playerProvider.notifier);
    // 有播放队列时对齐「相似歌曲」交互：插入当前歌曲下一首并切播；
    // 无队列时直接以该曲起播
    if (ref.read(playerProvider).hasQueue) {
      final String? error = await notifier.playSimilarNext(song.toTrack());
      if (!mounted) return;
      if (error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    } else {
      await notifier.playSongs(<Track>[song.toTrack()],
          queueTitle: widget.artistName);
    }
  }
}
