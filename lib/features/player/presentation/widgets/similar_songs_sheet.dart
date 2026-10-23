/// 相似歌曲底部弹窗（/simi/song）：
///  - 点击某首相似歌曲 → 立即插入到当前播放歌曲的下一首并切换播放；
///  - 列表带封面/歌手/VIP 徽标，顶部说明当前操作语义。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../../core/api/netease_models.dart' show Song;
import '../../../discover/data/netease_providers.dart'
    show neteaseRepositoryProvider;
import '../../../library/domain/track.dart';
import '../../providers/player_providers.dart';

/// 打开相似歌曲弹窗
Future<void> showSimilarSongsSheet(BuildContext context, Track current) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) => _SimilarSongsSheet(current: current),
  );
}

class _SimilarSongsSheet extends ConsumerStatefulWidget {
  const _SimilarSongsSheet({required this.current});

  final Track current;

  @override
  ConsumerState<_SimilarSongsSheet> createState() => _SimilarSongsSheetState();
}

class _SimilarSongsSheetState extends ConsumerState<_SimilarSongsSheet> {
  late final Future<List<Song>> _future;
  final Set<int> _busy = <int>{};
  final Set<int> _doneOk = <int>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    final int? songId = widget.current.neteaseId;
    _future = songId == null
        ? Future<List<Song>>.value(const <Song>[])
        : ref.read(neteaseRepositoryProvider).simiSongs(songId);
  }

  Future<void> _play(Song song) async {
    if (_busy.contains(song.id)) return;
    setState(() => _busy.add(song.id));
    final String? error = await ref
        .read(playerProvider.notifier)
        .playSimilarNext(song.toTrack());
    if (!mounted) return;
    setState(() {
      _busy.remove(song.id);
      if (error == null) {
        _doneOk.add(song.id);
      } else {
        _error = error;
      }
    });
    if (error == null && mounted) {
      // 插播成功：关闭弹窗回到播放页
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('正在播放相似歌曲「${song.name}」'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double maxH = MediaQuery.sizeOf(context).height * 0.7;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('相似歌曲',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  '点击立即切换播放，并加入「${widget.current.title}」的下一首',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(_error!,
                  style: const TextStyle(
                      fontSize: 12.5, color: AppConstants.brandColor)),
            ),
          Flexible(
            child: FutureBuilder<List<Song>>(
              future: _future,
              builder:
                  (BuildContext ctx, AsyncSnapshot<List<Song>> snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  );
                }
                final List<Song> songs = snapshot.data ?? const <Song>[];
                if (songs.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text('暂无相似歌曲推荐',
                        style:
                            TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16, top: 4),
                  itemCount: songs.length,
                  itemBuilder: (BuildContext ctx, int index) {
                    final Song s = songs[index];
                    final bool busy = _busy.contains(s.id);
                    return ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 20),
                      leading: CoverImage(src: s.coverUrl, size: 44, radius: 7),
                      title: Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: _doneOk.contains(s.id)
                                    ? AppConstants.brandColor
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          if (s.isVipOnly) ...<Widget>[
                            const SizedBox(width: 6),
                            Container(
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
                            ),
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
                      trailing: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.play_circle_outline_rounded,
                              size: 24,
                              color: theme.colorScheme.onSurfaceVariant),
                      onTap: () => _play(s),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
