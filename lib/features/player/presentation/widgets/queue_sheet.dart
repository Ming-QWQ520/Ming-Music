/// 播放列表底部弹窗（第十六批按参考图重做）：
///  - 「当前播放」与「历史播放」左右滑动切换（PageView，文字 tab + 下划线
///    指示器同步，计数以上标小字跟随在标签右上，如图「当前播放⁶⁴」）；
///  - 当前播放行：从左到右 = 当前播放标识（抖动条纹）→ VIP 标识
///    （是才显示）→ 「歌名 - 歌手」（歌手紧靠歌名，左右各一空格）；
///    行尾拖动按键（ReorderableListView 自定义排序）；
///  - 定位修复（第十六批）：打开弹窗/点击定位键 —— ListView.builder
///    懒构建导致深处行无 BuildContext，改两段式（估高跳转 → 锚点构建后
///    ensureVisible 精调）；
///  - 历史播放（参考图）：每个队列快照一个分组 —— 组头「来源名 + 删除」、
///    「继续播放：X」副标题、编号行「N. 歌名 · 歌手（VIP）」，
///    点行恢复该队列并从该行继续播放；
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/sheet_host.dart'
    show GlassSheet, showMingSheet;
import '../../../library/domain/track.dart';
import '../../../library/presentation/add_to_playlist_sheet.dart';
import '../../../discover/presentation/widgets/song_tile.dart' show VipBadge;
import '../../providers/cache_providers.dart'
    show cachedSongIdsProvider, networkAvailableProvider;
import '../../providers/player_providers.dart';
import '../../services/queue_persistence.dart' show QueueSnapshot;

/// 打开播放列表弹窗
///
/// 崩溃修复（logcat 实证 `Navigator.of` 空指针）：统一走 [showMingSheet]
/// —— 优先取全局 rootNavigatorKey，不再依赖 context 向上查 Navigator
///（播放页个别浮层的 context 不在 Navigator 之下，旧实现必炸）。
Future<void> showQueueSheet(BuildContext context) {
  return showMingSheet<void>(
    context,
    isScrollControlled: true,
    barrierLabel: '播放列表',
    builder: (BuildContext context) => const _QueueSheet(),
  );
}

class _QueueSheet extends ConsumerStatefulWidget {
  const _QueueSheet();

  @override
  ConsumerState<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<_QueueSheet> {
  /// 0 = 当前播放；1 = 历史播放（PageView 页码）
  final PageController _pageCtrl = PageController();
  int _page = 0;

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

    // 液态玻璃弹窗底板（需求）
    return GlassSheet(
      maxHeight: maxH,
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
          // 文字 Tab + 下划线指示器（参考图），与 PageView 双向联动
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            child: Row(
              children: <Widget>[
                GestureDetector(
                  onTap: () => _go(0),
                  child: _TabText(
                    label: '当前播放',
                    count: count,
                    active: _page == 0,
                  ),
                ),
                const SizedBox(width: 22),
                GestureDetector(
                  onTap: () => _go(1),
                  child: _TabText(
                    label: '历史播放',
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
              }),
              children: <Widget>[
                _CurrentPane(state: state, count: count),
                _HistoryPane(
                  history: history,
                  onDelete: (int i) =>
                      ref.read(queueHistoryProvider.notifier).removeAt(i),
                  onPlayFrom: (QueueSnapshot snap, int startAt) async {
                    Navigator.of(context).pop();
                    await ref.read(playerProvider.notifier).playSongs(
                          snap.tracks,
                          startIndex: startAt,
                          queueTitle: snap.title,
                        );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 文字 Tab

/// 文字 Tab（参考图）：标签 + 可选上标计数（如「当前播放⁶⁴」），
/// 选中态加粗 + 品牌色 + 底部下划线指示器

class _TabText extends StatelessWidget {
  const _TabText({required this.label, this.count, required this.active});

  final String label;
  final int? count;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final Color color = active
        ? AppConstants.brandColor
        : Colors.white.withValues(alpha: 0.62);
    final TextStyle style = TextStyle(
      fontSize: 14.5,
      fontWeight: active ? FontWeight.w800 : FontWeight.w500,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 上标计数：WidgetSpan 上移 4px 小字号（仿参考图「当前播放⁶⁴」）
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: label, style: style),
                if (count != null)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Transform.translate(
                      offset: const Offset(1.5, -4.5),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          // 下划线指示器（选中态展开）
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: active ? 18 : 0,
            height: 2.5,
            decoration: BoxDecoration(
              color: active ? AppConstants.brandColor : Colors.transparent,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 当前播放

class _CurrentPane extends ConsumerStatefulWidget {
  const _CurrentPane({required this.state, required this.count});

  final PlayerState state;
  final int count;

  @override
  ConsumerState<_CurrentPane> createState() => _CurrentPaneState();
}

class _CurrentPaneState extends ConsumerState<_CurrentPane> {
  /// 播放列表滚动控制（需求：打开时定位到当前播放歌曲）
  final ScrollController _scroll = ScrollController();

  /// 当前播放行锚点（需求修复：定位失效 —— 旧实现用固定行高估算，
  /// 实际行高随 VIP 徽标/换行变化导致误差；改用 GlobalKey 锚点 +
  /// Scrollable.ensureVisible 精确滚动）
  final GlobalKey _currentRowKey = GlobalKey();

  /// 两段式定位阶段：0 = 初始尝试；1 = 已按估高跳转待精调；2 = 完成
  int _locatePhase = 0;

  /// 估高跳转重试计数（防极端场景无限递归）
  int _locateJumps = 0;

  /// 行高估算：行内容单行 + 上下 10 padding（拖动键 32 为最高子项）
  static const double _kRowEstHeight = 52;

  @override
  void initState() {
    super.initState();
    // 需求：打开播放列表时定位到当前播放歌曲 —— 当前歌曲上方显示两首
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _locate(animate: false));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 滚动到当前播放歌曲：使其上方保留两行可见（近似居中偏上）
  void _locate({bool animate = true}) {
    if (!widget.state.hasQueue) return;
    _locatePhase = 0;
    _locateJumps = 0;
    _locateTick(animate);
  }

  /// 第十六批定位失效根治：
  ///
  /// 根因：ReorderableListView.builder 懒构建 —— 当前歌在列表深处时
  /// 行从未被构建，`_currentRowKey.currentContext` 恒为 null，
  /// Scrollable.ensureVisible 无从定位；旧实现重试 6 帧后放弃，
  /// 定位按钮与打开自动定位双双失效。
  ///
  /// 修复：两段式 —— 先按估高（行数 × _kRowEstHeight）直接跳到目标
  /// 附近（jumpTo/animateTo），行进入构建缓存后下一帧锚点就绪，
  /// 再 ensureVisible 精调到「上方保留两行」。
  void _locateTick(bool animate) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? ctx = _currentRowKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: animate ? const Duration(milliseconds: 260) : Duration.zero,
          curve: Curves.easeOutCubic,
          // 当前歌曲上方保留两行（与需求一致）
          alignment: 0.3,
        );
        _locatePhase = 2;
        return;
      }
      if (!_scroll.hasClients || _locatePhase >= 2) return;
      final double viewport = _scroll.position.viewportDimension;
      final double target =
          (widget.state.index * _kRowEstHeight - viewport * 0.3)
              .clamp(0.0, _scroll.position.maxScrollExtent);
      if (animate && _locatePhase == 0) {
        _locatePhase = 1;
        _scroll
            .animateTo(
              target,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() => _locateTick(false));
      } else {
        if (_locateJumps++ > 3) return; // 极端场景（锚点始终未构建）不再重试
        _locatePhase = 1;
        _scroll.jumpTo(target);
        // 跳转后下一帧行已构建，再走一次锚点精调
        _locateTick(false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlayerState state = widget.state;
    final int count = widget.count;
    if (count == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Text(
          '播放列表为空',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return Stack(
      children: <Widget>[
        Column(
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
                scrollController: _scroll,
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: count,
                onReorderItem: (int oldIndex, int newIndex) => ref
                    .read(playerProvider.notifier)
                    .reorderQueue(oldIndex, newIndex),
                proxyDecorator:
                    (Widget child, int index, Animation<double> anim) {
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
                  // 当前播放行挂锚点 key（定位用）；非当前行保持原样
                  final Widget row = _QueueRow(
                    key: ValueKey<String>('${t.id}_$index'),
                    track: t,
                    current: current,
                    playing: state.playing,
                    index: index,
                    onTap: () async {
                      Navigator.of(context).pop();
                      await ref.read(playerProvider.notifier).playAt(index);
                    },
                    onRemove: () => ref
                        .read(playerProvider.notifier)
                        .removeFromQueue(index),
                    onAddTo: () => showAddToPlaylistSheet(
                        context, ref, <int>[t.neteaseId ?? 0]),
                  );
                  if (!current) return row;
                  return KeyedSubtree(
                    key: _currentRowKey,
                    child: row,
                  );
                },
              ),
            ),
          ],
        ),
        // 需求：定位当前播放歌曲按键（滚动离开当前歌后可一键回位）
        Positioned(
          right: 16,
          bottom: 20,
          child: Tooltip(
            message: '定位当前歌曲',
            preferBelow: false,
            child: Material(
              color: AppConstants.darkSurface.withValues(alpha: 0.92),
              shape: const CircleBorder(
                side: BorderSide(color: Colors.white24, width: 1),
              ),
              clipBehavior: Clip.antiAlias,
              elevation: 2,
              child: InkWell(
                onTap: () => _locate(),
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.my_location_rounded,
                      size: 20, color: AppConstants.brandColor),
                ),
              ),
            ),
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
            0.70 * (0.5 + 0.5 * math.sin((phase + i * 0.28) * 2 * math.pi));
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

// ---------------------------------------------------------------- 历史播放

/// 历史播放分组列表（第十六批按参考图重做）：
///  - 每个队列快照一个分组：组头「来源名 + 删除键」→「继续播放：X」副标题
///    → 编号曲目行「N. 歌名 · 歌手（VIP）」；
///  - 点任意曲目行：恢复该队列并从该行开始播放（不打断语义由 playSongs 承接）。
class _HistoryPane extends StatelessWidget {
  const _HistoryPane({
    required this.history,
    required this.onDelete,
    required this.onPlayFrom,
  });

  final List<QueueSnapshot> history;
  final ValueChanged<int> onDelete;
  final void Function(QueueSnapshot snap, int startAt) onPlayFrom;

  /// 扁平化条目：组头 / 继续播放行 / 曲目行（避免嵌套滚动）
  List<_HistoryEntry> _flatten() {
    final List<_HistoryEntry> entries = <_HistoryEntry>[];
    for (int g = 0; g < history.length; g++) {
      final QueueSnapshot snap = history[g];
      entries.add(_HistoryEntry.header(g));
      if (snap.tracks.isNotEmpty) {
        entries.add(_HistoryEntry.continueLine(g));
        for (int i = 0; i < snap.tracks.length; i++) {
          entries.add(_HistoryEntry.track(g, i));
        }
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 56),
        child: Text(
          '暂无历史播放\n切换播放队列后会自动保留最近 3 个',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final List<_HistoryEntry> entries = _flatten();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16, top: 2),
      itemCount: entries.length,
      itemBuilder: (BuildContext context, int index) {
        final _HistoryEntry e = entries[index];
        final QueueSnapshot snap = history[e.group];
        switch (e.kind) {
          case _HistoryEntryKind.header:
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      snap.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w800),
                    ),
                  ),
                  // 组头右侧删除键（参考图）：删除该历史分组
                  IconButton(
                    tooltip: '删除该历史',
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () => onDelete(e.group),
                  ),
                ],
              ),
            );
          case _HistoryEntryKind.continueLine:
            final Track cur = snap.tracks[snap.currentIndex];
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    const TextSpan(
                      text: '继续播放：',
                      style: TextStyle(fontSize: 12.5, color: Colors.white38),
                    ),
                    TextSpan(
                      text: cur.title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          case _HistoryEntryKind.track:
            final int i = e.trackIndex;
            final Track t = snap.tracks[i];
            final bool isContinue = i == snap.currentIndex;
            return InkWell(
              onTap: () => onPlayFrom(snap, i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                child: Row(
                  children: <Widget>[
                    // 编号（参考图「1.」）；继续播放首行用品牌色呼应
                    SizedBox(
                      width: 26,
                      child: Text(
                        '${i + 1}.',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: isContinue
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: isContinue
                              ? AppConstants.brandColor
                              : Colors.white.withValues(alpha: 0.42),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: t.title,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: isContinue
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: Colors.white
                                    .withValues(alpha: isContinue ? 1 : 0.88),
                              ),
                            ),
                            TextSpan(
                              text: ' · ${t.artist}',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                            ),
                            if (t.isVipOnly)
                              const TextSpan(
                                text: '（VIP）',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
        }
      },
    );
  }
}

enum _HistoryEntryKind { header, continueLine, track }

class _HistoryEntry {
  const _HistoryEntry.header(this.group)
      : kind = _HistoryEntryKind.header,
        trackIndex = -1;
  const _HistoryEntry.continueLine(this.group)
      : kind = _HistoryEntryKind.continueLine,
        trackIndex = -1;
  const _HistoryEntry.track(this.group, this.trackIndex)
      : kind = _HistoryEntryKind.track;

  final int group;
  final _HistoryEntryKind kind;
  final int trackIndex;
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
    // 需求：无网时播放歌单中未缓存歌曲暗淡（有网一律正常；当前播放行
    // 保持红色高亮不受暗淡影响）
    final int? nid = track.neteaseId;
    final bool online = ref.watch(networkAvailableProvider
        .select((AsyncValue<bool> v) => v.valueOrNull ?? true));
    final bool cached = nid == null ||
        (ref.watch(cachedSongIdsProvider).valueOrNull ?? const <int>{})
            .contains(nid);
    final bool dim = !current && !online && !cached;
    final Color titleColor = current
        ? AppConstants.brandColor
        : theme.colorScheme.onSurface.withValues(alpha: dim ? 0.38 : 1.0);
    final Color artistColor =
        theme.colorScheme.onSurfaceVariant.withValues(alpha: dim ? 0.38 : 1.0);

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
            // ② VIP 标识（是才显示；无网未缓存同规则暗淡）
            if (track.isVipOnly) ...<Widget>[
              Opacity(opacity: dim ? 0.38 : 1.0, child: VipBadge(height: 13)),
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
                        color: artistColor,
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
                  color:
                      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
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
