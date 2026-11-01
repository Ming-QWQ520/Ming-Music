/// 当前播放标识：三根跳动的均衡器条纹（暂停时静止低幅）。
/// 播放列表弹窗（队列行首）与歌单详情页（行尾）共用同款动效 ——
/// 需求：歌单右侧「正在播放」动效与播放列表左侧动效统一。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/constants/app_constants.dart';

class EqBars extends StatefulWidget {
  const EqBars({super.key, required this.playing});

  final bool playing;

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
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
  void didUpdateWidget(EqBars oldWidget) {
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
