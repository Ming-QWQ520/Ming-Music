/// 播放列表底部弹窗（参考图5）：当前播放 N / 来自 xxx / 红色高亮当前行。
/// 历史列表：最多保留 3 个队列快照（播放列表持久化需求），可查看/恢复/删除。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../../discover/presentation/widgets/song_tile.dart' show VipBadge;
import '../../providers/player_providers.dart';
import '../../services/queue_persistence.dart' show QueueSnapshot;

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
  /// false = 当前播放；true = 历史列表
  bool _showHistory = false;

  /// 展开的历史快照下标
  int? _expandedHistory;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlayerState state = ref.watch(playerProvider);
    final List<QueueSnapshot> history = ref.watch(queueHistoryProvider);
    final int count = state.queue.length;
    final double maxH = MediaQuery.sizeOf(context).height * 0.72;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: BorderRadius.vertical(
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
          // Tab：当前播放 | 历史列表
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: <Widget>[
                _TabChip(
                  label: '当前播放 $count',
                  active: !_showHistory,
                  onTap: () => setState(() {
                    _showHistory = false;
                    _expandedHistory = null;
                  }),
                ),
                const SizedBox(width: 10),
                _TabChip(
                  label: '历史列表 ${history.length}',
                  active: _showHistory,
                  onTap: () => setState(() {
                    _showHistory = true;
                    _expandedHistory = null;
                  }),
                ),
                const Spacer(),
                if (!_showHistory)
                  IconButton(
                    tooltip: '清空列表',
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 21,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: count == 0
                        ? null
                        : () =>
                            ref.read(playerProvider.notifier).clearQueue(),
                  ),
              ],
            ),
          ),
          Flexible(
            child: _showHistory
                ? _HistoryPane(
                    history: history,
                    expanded: _expandedHistory,
                    onToggleExpand: (int i) => setState(() {
                      _expandedHistory = _expandedHistory == i ? null : i;
                    }),
                    onRestore: (QueueSnapshot snap) async {
                      Navigator.of(context).pop();
                      await ref
                          .read(playerProvider.notifier)
                          .playSongs(snap.tracks,
                              queueTitle: snap.title);
                    },
                    onDelete: (int i) =>
                        ref.read(queueHistoryProvider.notifier).removeAt(i),
                  )
                : _CurrentPane(state: state, count: count),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Tab 胶囊

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? AppConstants.brandColor.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            color: active
                ? AppConstants.brandColor
                : Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 当前播放

class _CurrentPane extends ConsumerWidget {
  const _CurrentPane({required this.state, required this.count});

  final PlayerState state;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    if (count == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Text(
          '播放列表为空',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (state.queueTitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
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
          child: ListView.builder(
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
    );
  }
}

// ---------------------------------------------------------------- 历史列表

class _HistoryPane extends StatelessWidget {
  const _HistoryPane({
    required this.history,
    required this.expanded,
    required this.onToggleExpand,
    required this.onRestore,
    required this.onDelete,
  });

  final List<QueueSnapshot> history;
  final int? expanded;
  final ValueChanged<int> onToggleExpand;
  final ValueChanged<QueueSnapshot> onRestore;
  final ValueChanged<int> onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Text(
          '暂无历史列表\n切换播放队列后会自动保留最近 3 个',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16, top: 6),
      itemCount: history.length,
      itemBuilder: (BuildContext context, int index) {
        final QueueSnapshot snap = history[index];
        final bool isOpen = expanded == index;
        return Column(
          children: <Widget>[
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
              leading: Icon(
                isOpen
                    ? Icons.folder_open_rounded
                    : Icons.folder_rounded,
                size: 22,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(
                snap.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5),
              ),
              subtitle: Text(
                '${snap.tracks.length} 首 · ${_formatTime(snap.savedAt)}',
                style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: '播放此列表',
                    icon: const Icon(Icons.play_circle_outline_rounded,
                        size: 22, color: AppConstants.brandColor),
                    onPressed: () => onRestore(snap),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: Icon(Icons.close_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant),
                    onPressed: () => onDelete(index),
                  ),
                ],
              ),
              onTap: () => onToggleExpand(index),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 180),
              crossFadeState: isOpen
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Container(
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: snap.tracks.length,
                  itemBuilder: (BuildContext ctx, int ti) {
                    final Track t = snap.tracks[ti];
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 24),
                      leading: CoverImage(src: t.cover, size: 32, radius: 5),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        t.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.month}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
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
