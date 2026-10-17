/// 播放列表底部弹窗（参考图5）：当前播放 N / 来自 xxx / 红色高亮当前行。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../../discover/presentation/widgets/song_tile.dart' show VipBadge;
import '../../providers/player_providers.dart';

/// 打开播放列表弹窗
Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) => const _QueueSheet(),
  );
}

class _QueueSheet extends ConsumerStatefulWidget {
  const _QueueSheet();

  @override
  ConsumerState<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<_QueueSheet> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlayerState state = ref.watch(playerProvider);
    final int count = state.queue.length;
    final double maxH = MediaQuery.sizeOf(context).height * 0.72;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(22),
        ),
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
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            child: Row(
              children: <Widget>[
                Text(
                  '当前播放',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '清空列表',
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 21,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: count == 0
                      ? null
                      : () => ref.read(playerProvider.notifier).clearQueue(),
                ),
              ],
            ),
          ),
          if (state.queueTitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '来自：${state.queueTitle}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Flexible(
            child: count == 0
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 56),
                    child: Text(
                      '播放列表为空',
                      style:
                          TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: count,
                    itemBuilder: (BuildContext context, int index) {
                      final Track t = state.queue[index];
                      final bool current = index == state.index;
                      return _QueueRow(
                        track: t,
                        current: current,
                        onTap: () async {
                          Navigator.of(context).pop();
                          await ref.read(playerProvider.notifier).playAt(index);
                        },
                        onRemove: () => ref
                            .read(playerProvider.notifier)
                            .removeFromQueue(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.track,
    required this.current,
    required this.onTap,
    required this.onRemove,
  });

  final Track track;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color titleColor =
        current ? AppConstants.brandColor : theme.colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: <Widget>[
            if (current) ...<Widget>[
              const Icon(
                Icons.volume_up_rounded,
                color: AppConstants.brandColor,
                size: 18,
              ),
              const SizedBox(width: 4),
            ] else
              const SizedBox(width: 22),
            if (track.isVipOnly) ...<Widget>[
              const VipBadge(height: 13),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: titleColor,
                  fontSize: 15.5,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              track.artist,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: onRemove,
            ),
            CoverImage(src: track.cover, size: 38, radius: 6),
          ],
        ),
      ),
    );
  }
}
