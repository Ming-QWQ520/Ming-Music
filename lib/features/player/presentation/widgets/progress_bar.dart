/// 播放进度条（需求：Apple Music 样式 —— 自绘双层圆角条）：
///  - 无头部圆点；「当前进度条」与「总进度条」**完全等高等大**（同一
///    trackHeight，旧 M3 Slider 实现两条观感粗细不一致的问题根除）；
///  - 手动拖动时两条**以同一倍数平滑变粗**（4 → 8），松手回弹 ——
///    Apple Music 效果；
///  - 高潮点白点：**固定小尺寸**（6px，第十二批需求修复 —— 旧实现
///    9px ≈ 拖动态条高，用户观感“点的大小是拖动时放大后的总条”），
///    不随拖动放大，仅显示不拦截拖动；
///  - 自绘替代 SliderTheme：根治 M3 RoundedRectTrackShape 在无圆点
///    配置下 active/inactive 分段圆角与间隙的观感差异，并保证轨道
///    两侧内收与 m:s 时间标签对齐；
///  - 拖动期间使用本地预览值，松手才真正 seek；
///  - 只订阅 positionProvider / durationProvider，RepaintBoundary 隔离；
///  - 高潮点（副歌）白点仅显示不响应点击（保留长按气泡提示）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/duration_utils.dart';
import '../../providers/player_providers.dart';

class PlayerProgressBar extends ConsumerStatefulWidget {
  const PlayerProgressBar({super.key, this.compact = false, this.centerLabel});

  final bool compact;

  /// 进度行中央标签（仿网易云：音质标识）
  final Widget? centerLabel;

  @override
  ConsumerState<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends ConsumerState<PlayerProgressBar> {
  double? _previewMs;

  /// 是否正在拖动（Apple Music：拖动时两条一起变粗）
  bool _dragging = false;

  /// 常规/拖动态的条高（Apple Music 观感：4 → 8）
  static const double _kRestHeight = 4;
  static const double _kDragHeight = 8;

  /// 轨道两侧内收量：与时间标签行的水平 padding 一致，
  /// 需求「进度条不要超过 m:s 标签」
  static const double _kTrackInset = 16;

  void _seekToDx(double dx, double width) {
    final double safeWidth = math.max(1.0, width - _kTrackInset * 2);
    final double frac = ((dx - _kTrackInset) / safeWidth).clamp(0.0, 1.0);
    final double durationMs =
        ref.read(durationProvider).value?.inMilliseconds.toDouble() ?? 0;
    if (durationMs <= 0) return;
    setState(() {
      _previewMs = frac * durationMs;
      _dragging = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double positionMs =
        ref.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double durationMs =
        ref.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double safeDuration = durationMs > 0 ? durationMs : 1;

    final double value = (_previewMs ?? positionMs.clamp(0, safeDuration))
        .clamp(0, safeDuration);

    // 高潮点（副歌起点，毫秒）：null = 无数据不显示白点
    final int? chorusMs =
        widget.compact ? null : ref.watch(currentChorusStartProvider);

    final Widget bar = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _dragging ? _kDragHeight : _kRestHeight),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (BuildContext ctx, double height, _) {
        // 自绘双层圆角条：当前进度条与总进度条同一高度同一圆角
        //（需求修复：旧 M3 Slider 两条粗细观感不一致）
        return SizedBox(
          height: math.max(height, _kDragHeight),
          child: Center(
            child: LayoutBuilder(
              builder: (BuildContext ctx, BoxConstraints cons) {
                final double w = cons.maxWidth;
                final double filled = (w - _kTrackInset * 2) *
                    (value / safeDuration).clamp(0.0, 1.0);
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    // 总进度条（底）：白 25%
                    Positioned(
                      left: _kTrackInset,
                      right: _kTrackInset,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Container(
                          height: height,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(height / 2),
                          ),
                        ),
                      ),
                    ),
                    // 当前进度条：白 90%，与总条同高同大
                    Positioned(
                      left: _kTrackInset,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Container(
                          width: math.max(filled, height),
                          height: height,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(height / 2),
                          ),
                        ),
                      ),
                    ),
                    // 高潮点白点：仅显示（不拦截拖动），位置对齐轨道
                    if (chorusMs != null &&
                        chorusMs > 0 &&
                        chorusMs < safeDuration)
                      Positioned(
                        left: (_kTrackInset +
                                (w - _kTrackInset * 2) *
                                    (chorusMs / safeDuration).clamp(0.0, 1.0) -
                                17)
                            .clamp(0.0, math.max(0.0, w - 34)),
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Tooltip(
                            message:
                                '高潮点 ${Duration(milliseconds: chorusMs).clock}',
                            triggerMode: TooltipTriggerMode.longPress,
                            preferBelow: false,
                            verticalOffset: 24,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            textStyle: const TextStyle(
                                fontSize: 11.5, color: Colors.white),
                            // 命中区放宽到 34x30，白点本体固定 6px
                            //（第十二批需求：不随拖动变大的总进度条尺寸）
                            child: SizedBox(
                              width: 34,
                              height: 30,
                              child: Center(
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white,
                                    border: Border.all(
                                      color:
                                          Colors.black.withValues(alpha: 0.35),
                                      width: 1,
                                    ),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color:
                                            Colors.black.withValues(alpha: 0.4),
                                        blurRadius: 3,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 手势层：点按/拖动均可定位（拖动期间两条同步放大）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails d) {
              final RenderBox? box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _seekToDx(box.globalToLocal(d.globalPosition).dx, box.size.width);
            },
            onHorizontalDragStart: (DragStartDetails d) {
              final RenderBox? box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _seekToDx(box.globalToLocal(d.globalPosition).dx, box.size.width);
            },
            onHorizontalDragUpdate: (DragUpdateDetails d) {
              final RenderBox? box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _seekToDx(box.globalToLocal(d.globalPosition).dx, box.size.width);
            },
            onHorizontalDragEnd: (DragEndDetails d) {
              final double? v = _previewMs;
              setState(() => _dragging = false);
              _previewMs = null;
              if (v != null) {
                ref
                    .read(playerProvider.notifier)
                    .seek(Duration(milliseconds: v.round()));
              }
            },
            child: bar,
          ),
          Padding(
            // 与轨道内收量一致：时间文本与轨道端点齐平
            padding: const EdgeInsets.only(
                left: _kTrackInset, right: _kTrackInset, top: 2),
            child: Row(
              children: <Widget>[
                Text(
                  Duration(milliseconds: value.round()).clock,
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                    color: Colors.white.withValues(alpha: 0.62),
                  ),
                ),
                Expanded(
                  child: Center(
                      child: widget.centerLabel ?? const SizedBox.shrink()),
                ),
                Text(
                  Duration(milliseconds: safeDuration.round()).clock,
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                    color: Colors.white.withValues(alpha: 0.62),
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
