/// 播放进度条（需求：Apple Music 样式）：
///  - 无头部圆点（thumb/overlay 全隐藏），进度条为一个整体圆角条；
///  - 手动拖动时进度条平滑变粗（缩放变大），松手回弹到常规粗细；
///  - 只订阅 positionProvider / durationProvider 两个高频流，
///    并用 RepaintBoundary 把重绘隔离在本组件内；
///  - 拖动期间使用本地预览值，松手才真正 seek。
library;

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

  /// 是否正在拖动（Apple Music：拖动时条变粗）
  bool _dragging = false;

  /// 常规/拖动态的条高（Apple Music 观感：4 → 8）
  static const double _kRestHeight = 4;
  static const double _kDragHeight = 8;

  @override
  Widget build(BuildContext context) {
    final double positionMs =
        ref.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double durationMs =
        ref.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double safeDuration = durationMs > 0 ? durationMs : 1;

    final double value = (_previewMs ?? positionMs.clamp(0, safeDuration))
        .clamp(0, safeDuration);

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 需求：拖动时进度条缩放变大 —— trackHeight 用隐式动画平滑过渡
          TweenAnimationBuilder<double>(
            tween: Tween<double>(
                end: _dragging ? _kDragHeight : _kRestHeight),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            builder: (BuildContext ctx, double height, _) {
              return SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  // Apple Music：无圆点，条为一个整体
                  thumbShape: SliderComponentShape.noThumb,
                  overlayShape: SliderComponentShape.noOverlay,
                  trackShape: const RoundedRectSliderTrackShape(),
                  trackHeight: height,
                  activeTrackColor: Colors.white.withValues(alpha: 0.9),
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.25),
                ),
                child: Slider(
                  value: value,
                  max: safeDuration,
                  onChanged: (double v) =>
                      setState(() { _previewMs = v; _dragging = true; }),
                  onChangeEnd: (double v) {
                    setState(() => _dragging = false);
                    _previewMs = null;
                    ref
                        .read(playerProvider.notifier)
                        .seek(Duration(milliseconds: v.round()));
                  },
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
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
                  child: Center(child: widget.centerLabel ?? const SizedBox.shrink()),
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
