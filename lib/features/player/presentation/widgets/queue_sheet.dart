/// 播放列表底部弹窗（仿网易云）：
///  - 「当前播放」与「历史列表」左右滑动切换（PageView，Tab 胶囊同步）；
///  - 当前播放行（需求）：从左到右 = 当前播放标识（抖动条纹）→ VIP 标识
///    （是才显示）→ 「歌名 - 歌手」（歌手紧靠歌名，左右各一空格）；
///    移除行尾 x 删除键与封面；行尾为拖动按键（ReorderableListView 自定义排序）；
///  - 历史列表：最多保留 3 个队列快照，可展开/恢复/删除。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../library/domain/track.dart';
import '../../../library/presentation/add_to_playlist_sheet.dart';
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
  /// 0 = 当前播放；1 = 历史列表（PageView 页码）
  final PageController _pageCtrl = PageController();
  int _page = 0;

  /// 展开的历史快照下标
  int? _expandedHistory;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _go(int page) {
    _pageCtrl.animateToPage(
      page,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

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
          // Tab 胶囊：与 PageView 双向联动（点击切换 / 滑动同步高亮）
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            child: Row(
              children: <Widget>[
                GestureDetector(
                  onTap: () => _go(0),
                  child: _TabChip(
                    label: '当前播放 $count',
                    active: _page == 0,
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => _go(1),
                  child: _TabChip(
                    label: '历史列表 ${history.length}',
                    active: _page == 1,
                  ),
                ),
                const Spacer(),
                if (_page == 0)
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
          Flexible(
            child: PageView(
              controller: _pageCtrl,
              onPageChanged: (int p) => setState(() {
                _page = p;
                _expandedHistory = null;
              }),
              children: <Widget>[
                _CurrentPane(state: state, count: count),
                _HistoryPane(
                  history: history,
                  expanded: _expandedHistory,
                  onToggleExpand: (int i) => setState(() {
                    _expandedHistory = _expandedHistory == i ? null : i;
                  }),
                  onRestore: (QueueSnapshot snap) async {
                    Navigator.of(context).pop();
                    await ref
                        .read(playerProvider.notifier)
                        .playSongs(snap.tracks, queueTitle: snap.title);
                  },
                  onDelete: (int i) =>
                      ref.read(queueHistoryProvider.notifier).removeAt(i),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Tab 胶囊

class _TabChip extends StatelessWidget {
  const _TabChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
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
          // 需求：拖动按键可对歌曲自定义排序
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: count,
            onReorderItem: (int oldIndex, int newIndex) =>
                ref.read(playerProvider.notifier).reorderQueue(oldIndex, newIndex),
            proxyDecorator: (Widget child, int index, Animation<double> anim) {
              return AnimatedBuilder(
                animation: anim,
                builder: (BuildContext ctx, Widget? w) => Material(
                  color: Colors.white
                      .withValues(alpha: 0.06 * anim.value.clamp(0.0, 1.0)),
                  borderRadius: BorderRadius.circular(12),
                  elevation: 0,
                  child: w,
                ),
                child: child,
              );
            },
            itemBuilder: (BuildContext context, int index) {
              final Track t = state.queue[index];
              final bool current = index == state.index;
              return _QueueRow(
                key: ValueKey<String>('${t.id}_$index'),
                track: t,
                current: current,
                playing: state.playing,
                index: index,
                onTap: () async {
                  Navigator.of(context).pop();
                  await ref.read(playerProvider.notifier).playAt(index);
                },
                onRemove: () =>
                    ref.read(playerProvider.notifier).removeFromQueue(index),
                onAddTo: () =>
                    showAddToPlaylistSheet(context, ref, <int>[t.neteaseId ?? 0]),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 抖动条纹

/// 当前播放标识：三根跳动的均衡器条纹（暂停时静止低幅）
class _EqBars extends StatefulWidget {
  const _EqBars({required this.playing});

  final bool playing;

  @override
  State<_EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<_EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(_EqBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (BuildContext ctx, Widget? _) {
          return CustomPaint(
            painter: _EqBarsPainter(
              phase: _ctrl.value,
              playing: widget.playing,
            ),
          );
        },
      ),
    );
  }
}

class _EqBarsPainter extends CustomPainter {
  const _EqBarsPainter({
    required this.phase,
    required this.playing,
  });

  final double phase;
  final bool playing;

  @override
  void paint(Canvas canvas, Size size) {
    const int bars = 3;
    final double bw = size.width / (bars * 2 - 1); // 条宽 = 间隙宽
    final Paint p = Paint()..color = AppConstants.brandColor;
    for (int i = 0; i < bars; i++) {
      double f;
      if (playing) {
        // 三根条纹按相位错开正弦跳动
        f = 0.30 +
            0.70 *
                (0.5 +
                    0.5 * math.sin((phase + i * 0.28) * 2 * math.pi));
      } else {
        f = 0.32;
      }
      final double h = size.height * f.clamp(0.12, 1.0);
      final double x = i * bw * 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, bw, h),
          Radius.circular(bw / 2),
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_EqBarsPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.playing != playing;
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
                isOpen ? Icons.folder_open_rounded : Icons.folder_rounded,
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
                      leading: const SizedBox(width: 8),
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

// ---------------------------------------------------------------- 行

/// 当前播放行（需求布局，从左到右）：
/// 抖动条纹（当前曲才显示）→ VIP 标识（是才显示）→ 歌名 - 歌手
/// → 移除键（x）+ 拖动按键；
/// 手势（需求）：左滑 = 删除出队列；右滑 = 添加至歌单（底部弹出菜单）。
class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    super.key,
    required this.track,
    required this.current,
    required this.playing,
    required this.index,
    required this.onTap,
    required this.onRemove,
    required this.onAddTo,
  });

  final Track track;
  final bool current;
  final bool playing;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onAddTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color titleColor =
        current ? AppConstants.brandColor : theme.colorScheme.onSurface;

    final Widget row = InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            // ① 当前播放标识（抖动条纹）；非当前曲占位对齐
            SizedBox(
              width: 16,
              height: 16,
              child: current ? _EqBars(playing: playing) : null,
            ),
            const SizedBox(width: 8),
            // ② VIP 标识（是才显示）
            if (track.isVipOnly) ...<Widget>[
              const VipBadge(height: 13),
              const SizedBox(width: 6),
            ],
            // ③ 「歌名 - 歌手」：歌手紧靠歌名，左右各一空格（单行 ellipsis）
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: track.title,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 15.5,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    const TextSpan(
                      text: ' - ',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 13.5,
                      ),
                    ),
                    TextSpan(
                      text: track.artist,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            // ④ 移除键（需求：补回移除按键；右滑删除等效）
            SizedBox(
              width: 30,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: '移除',
                icon: Icon(
                  Icons.close_rounded,
                  size: 17,
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.8),
                ),
                onPressed: onRemove,
              ),
            ),
            // ⑤ 拖动按键（自定义排序）
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.drag_handle_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // 手势（需求）：左滑 = 移除出队列；右滑 = 添加至歌单
    // Dismissible 语义：secondaryBackground 对应 endToStart（左滑）；
    // background 对应 startToEnd（右滑）。两种滑动都不自行移除条目
    // （删除由 provider 重建驱动，添加只弹菜单）。
    return Dismissible(
      key: ValueKey<String>('swipe_${track.id}_$index'),
      confirmDismiss: (DismissDirection dir) async {
        if (dir == DismissDirection.endToStart) {
          onRemove(); // 左滑 → 删除
          return false; // 状态由 removeAt 驱动，动画交给列表重建
        }
        onAddTo(); // 右滑 → 添加至歌单
        return false;
      },
      background: _SwipeBg(
        color: const Color(0xFF3D7BFF),
        icon: Icons.playlist_add_rounded,
        label: '添加到歌单',
        alignRight: false,
      ),
      secondaryBackground: _SwipeBg(
        color: AppConstants.brandColor,
        icon: Icons.remove_circle_outline_rounded,
        label: '删除',
        alignRight: true,
      ),
      child: row,
    );
  }
}

/// 滑动操作背景
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
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
          ],
          Icon(icon, color: Colors.white, size: 18),
          if (!alignRight) ...<Widget>[
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}
