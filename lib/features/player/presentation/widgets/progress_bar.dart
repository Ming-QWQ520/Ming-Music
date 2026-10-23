/// 播放进度条（需求：Apple Music 样式）：
///  - 无头部圆点（thumb/overlay 全隐藏），进度条为一个整体圆角条；
///  - 手动拖动时进度条平滑变粗（缩放变大），松手回弹到常规粗细；
///  - 只订阅 positionProvider / durationProvider 两个高频流，
///    并用 RepaintBoundary 把重绘隔离在本组件内；
///  - 拖动期间使用本地预览值，松手才真正 seek；
///  - 需求修复：进度条左右不再超过 m:s 时间标签 —— M3 轨道在无圆点
///    配置下满宽渲染（BaseSliderTrackShape：overlay/thumb 宽 0 → 内收 0），
///    自定义 track shape 强制轨道两侧内收 16px，与时间行 padding 对齐；
///  - 需求新增：高潮点（副歌）白点 —— /song/chorus 首个 startTime
///    （Zephyr-Music 方式），显示在轨道对应位置，点击跳转高潮点。
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

  /// 是否正在拖动（Apple Music：拖动时条变粗）
  bool _dragging = false;

  /// 常规/拖动态的条高（Apple Music 观感：4 → 8）
  static const double _kRestHeight = 4;
  static const double _kDragHeight = 8;

  /// 轨道两侧内收量：与时间标签行的水平 padding 一致，
  /// 需求「进度条不要超过 m:s 标签」
  static const double _kTrackInset = 16;

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

    final Widget slider = TweenAnimationBuilder<double>(
      tween:
          Tween<double>(end: _dragging ? _kDragHeight : _kRestHeight),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (BuildContext ctx, double height, _) {
        return SliderTheme(
          data: SliderTheme.of(context).copyWith(
            // Apple Music：无圆点，条为一个整体
            thumbShape: SliderComponentShape.noThumb,
            overlayShape: SliderComponentShape.noOverlay,
            // 需求：轨道两侧内收 16px，与时间标签对齐（不再超出 m:s）
            trackShape: const _AlignedTrackShape(inset: _kTrackInset),
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
    );

    // 高潮点白点：Stack 叠加在轨道对应位置（不占额外布局空间），
    // 点击跳转副歌起点（Zephyr-Music 方式）
    final Widget sliderWithDot;
    if (chorusMs != null && chorusMs > 0 && chorusMs < safeDuration) {
      sliderWithDot = LayoutBuilder(
        builder: (BuildContext ctx, BoxConstraints cons) {
          final double w = cons.maxWidth;
          final double frac = chorusMs / safeDuration;
          final double dotX = _kTrackInset + frac * (w - _kTrackInset * 2);
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              slider,
              Positioned(
                left: (dotX - 17).clamp(0.0, math.max(0.0, w - 34)),
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => ref
                        .read(playerProvider.notifier)
                        .seek(Duration(milliseconds: chorusMs)),
                    // 长按气泡提示（与底部功能条同规范）
                    child: Tooltip(
                      message: '高潮点 ${Duration(milliseconds: chorusMs).clock}',
                      triggerMode: TooltipTriggerMode.longPress,
                      preferBelow: false,
                      verticalOffset: 24,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      textStyle: const TextStyle(
                          fontSize: 11.5, color: Colors.white),
                      // 命中区放宽到 34x30，白点本体 9px
                      child: SizedBox(
                        width: 34,
                        height: 30,
                        child: Center(
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                color: Colors.black.withValues(alpha: 0.35),
                                width: 1,
                              ),
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
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
      );
    } else {
      sliderWithDot = slider;
    }

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          sliderWithDot,
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

/// 两侧内收的圆角轨道：M3 无圆点配置下轨道满宽渲染，导致进度条比
/// 下方 m:s 时间标签更长；本 shape 强制轨道左右各内收 [inset] 像素
/// （与时间行 padding 对齐），渲染逻辑（圆角/active-inactive 分段）不变。
class _AlignedTrackShape extends RoundedRectSliderTrackShape {
  const _AlignedTrackShape({this.inset = 0});

  final double inset;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final double trackHeight = sliderTheme.trackHeight ?? 4.0;
    final double width = (parentBox.size.width - inset * 2)
        .clamp(0.0, parentBox.size.width);
    final double left = offset.dx + inset;
    final double top = offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(left, top, width, trackHeight);
  }
}
