/// 我的音乐页：收藏曲目（网易云）+ 自定义网络直链曲目。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../domain/track.dart';
import '../providers/library_providers.dart';
import '../../discover/presentation/widgets/song_tile.dart' show VipBadge;
import '../../player/providers/player_providers.dart';
import 'add_network_sheet.dart';

class MyMusicPage extends ConsumerWidget {
  const MyMusicPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> favorites = ref.watch(favoriteTracksProvider);
    final List<Track> custom = ref.watch(libraryProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          '我的',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: <Widget>[
          // 收藏头部卡
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.favorite_rounded,
                  color: AppConstants.brandColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '我喜欢的音乐 (${favorites.length})',
                  style: const TextStyle(
                      fontSize: 16.5, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (favorites.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _playAll(ref, favorites, '我的收藏'),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('播放全部'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppConstants.brandColor,
                      textStyle: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
          if (favorites.isEmpty)
            _EmptyHint(text: '在歌曲详情或播放页点击红心，即可收藏到这里')
          else
            ...List<Widget>.generate(favorites.length, (int i) {
              final Track t = favorites[i];
              return _FavRow(
                track: t,
                current: ref.watch(playerProvider
                    .select((PlayerState s) => s.currentTrack?.id == t.id)),
                onTap: () => _playAt(ref, favorites, i),
                onMore: () => _confirmUnfavorite(context, ref, t),
              );
            }),

          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.link_rounded,
                  size: 20,
                  color: Colors.white70,
                ),
                const SizedBox(width: 8),
                Text(
                  '自定义直链 (${custom.length})',
                  style: const TextStyle(
                      fontSize: 16.5, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => showAddNetworkSheet(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('添加'),
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
          if (custom.isEmpty)
            const _EmptyHint(text: '支持添加任意可公开访问的音频直链')
          else
            ...List<Widget>.generate(custom.length, (int i) {
              final Track t = custom[i];
              return _FavRow(
                track: t,
                current: ref.watch(playerProvider
                    .select((PlayerState s) => s.currentTrack?.id == t.id)),
                onTap: () => _playAt(ref, custom, i),
                onMore: () =>
                    ref.read(libraryProvider.notifier).removeCustomTrack(t.id),
              );
            }),
        ],
      ),
    );
  }

  void _playAll(WidgetRef ref, List<Track> tracks, String title) {
    ref.read(playerProvider.notifier).playSongs(tracks, queueTitle: title);
  }

  void _playAt(WidgetRef ref, List<Track> tracks, int index) {
    ref.read(playerProvider.notifier).playSongs(tracks, startIndex: index);
  }

  Future<void> _confirmUnfavorite(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定不再喜欢「${track.title}」吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(favoriteTracksProvider.notifier).toggle(track);
    }
  }
}

class _FavRow extends StatelessWidget {
  const _FavRow({
    required this.track,
    required this.current,
    required this.onTap,
    required this.onMore,
  });

  final Track track;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: <Widget>[
            CoverImage(src: track.cover, size: 46, radius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                            color: current
                                ? AppConstants.brandColor
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (track.isVipOnly) ...<Widget>[
                        const SizedBox(width: 6),
                        const VipBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${track.artist} · ${track.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
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
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13.5,
        ),
      ),
    );
  }
}
