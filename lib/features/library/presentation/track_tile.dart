/// 曲目列表瓦片（库 / 收藏共用）。
///
/// ⚠️ 避坑指南 3：禁止 `ref.watch(playerProvider)` 监听整个 PlayerState，
/// 必须用 `select` 只订阅 isCurrent / playing 两个标量，
/// 否则任何播放状态变化都会重建列表里的每一行。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/duration_utils.dart';
import '../../../core/widgets/cover_image.dart';
import '../domain/track.dart';
import '../providers/library_providers.dart';
import '../../player/providers/player_providers.dart';

class TrackTile extends ConsumerWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.index,
    this.queue,
  });

  final Track track;
  final int index;

  /// 点击本行时要播放的队列；收藏页传收藏子集，
  /// 缺省回落到完整音乐库（避免用收藏下标错位索引全库队列）。
  final List<Track>? queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select 精细订阅：只有「当前曲目 id」或「播放中」变化才重建本行
    final String? currentId =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack?.id));
    final bool isCurrent = currentId == track.id;
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    final bool fav = ref.watch(
        favoriteIdsProvider.select((Set<String> s) => s.contains(track.id)));
    final bool isCustom = track.isCustom;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          onTap: () {
            final List<Track> playQueue = queue ?? ref.read(libraryProvider);
            ref
                .read(playerProvider.notifier)
                .playQueue(playQueue, startIndex: index);
          },
          leading: Stack(
            children: <Widget>[
              CoverImage(src: track.cover, size: 48, radius: 14),
              if (isCurrent && playing)
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      color: Color(0x54000000),
                    ),
                    child: Center(
                      child: Icon(Icons.graphic_eq_rounded,
                          size: 20, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
              color: isCurrent
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
          subtitle: Text(
            '${track.artist} · ${track.album}'
            '${track.durationMs != null ? ' · ${Duration(milliseconds: track.durationMs!).clock}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isCustom)
                IconButton(
                  tooltip: '移除',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _confirmRemove(context, ref),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              IconButton(
                tooltip: fav ? '取消收藏' : '收藏',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    ref.read(favoriteIdsProvider.notifier).toggle(track.id),
                icon: Icon(
                  fav ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                  size: 21,
                  color: fav
                      ? const Color(0xFFFF7BA0)
                      : Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('移除曲目'),
        content: Text('确定移除「${track.title}」吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(libraryProvider.notifier).removeCustomTrack(track.id);
    }
  }
}
