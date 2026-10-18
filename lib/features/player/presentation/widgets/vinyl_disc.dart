/// 黑胶唱片组件（参考图3 播放页主视觉）：
///  - 黑胶底盘：径向渐变 + CustomPaint 同心纹理环；
///  - 中心封面圆形；播放时唱片持续旋转（暂停保持当前角度）；
///  - 唱针：支点 + 针臂 + 针头，播放时搭下、暂停时抬起（AnimatedRotation）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';

class VinylDisc extends StatefulWidget {
  const VinylDisc({
    super.key,
    required this.cover,
    required this.playing,
    this.size = 280,
  });

  final String? cover;
  final bool playing;

  /// 唱片外径
  final double size;

  @override
  State<VinylDisc> createState() => _VinylDiscState();
}

class _VinylDiscState extends State<VinylDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: AppConstants.rotationPeriod,
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _rotation.repeat();
  }

  @override
  void didUpdateWidget(VinylDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      if (widget.playing) {
        _rotation.repeat();
      } else {
        _rotation.stop(); // 保持当前角度，与真实黑胶一致
      }
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size;
    // 需求：黑胶黑色范围缩小 —— 封面占比 0.46 → 0.64（黑边：封面 ≈ 0.56:1）
    final double coverSize = size * 0.64;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: <Widget>[
        SizedBox(
          width: size,
          height: size,
          child: RotationTransition(
            turns: _rotation,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                // 黑胶底盘 + 纹理
                CustomPaint(
                  size: Size.square(size),
                  painter: _VinylPainter(),
                ),
                // 中心封面
                Container(
                  width: coverSize,
                  height: coverSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.10),
                      width: 1.5,
                    ),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: CoverImage(
                      src: widget.cover,
                      size: coverSize,
                      radius: coverSize / 2,
                      coverSize: CoverSize.large,
                    ),
                  ),
                ),
                // 封面中心孔
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0E0E0E),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                      width: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 唱针（仿网易云：支点在唱片右上角外侧，斜搭向盘心；
        // 播放时落下贴盘，暂停时向外抬起）
        Positioned(
          top: -size * 0.06,
          right: size * 0.06,
          child: _Tonearm(size: size, playing: widget.playing),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- painter

class _VinylPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.width / 2;
    final Offset c = Offset(r, r);

    // 底盘：径向渐变（外缘略暗）
    final Paint disc = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          const Color(0xFF2E2E30),
          const Color(0xFF232325),
          const Color(0xFF19191B),
        ],
        stops: const <double>[0.18, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, disc);

    // 同心纹理环（模拟黑胶刻纹）：从封面外缘开始
    final Paint groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.035);
    final math.Random rng = math.Random(7);
    double radius = r * 0.70;
    while (radius < r * 0.94) {
      canvas.drawCircle(c, radius, groove);
      radius += 5 + rng.nextDouble() * 6;
    }

    // 外缘高光环
    final Paint rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..shader = SweepGradient(
        colors: <Color>[
          Colors.white.withValues(alpha: 0.10),
          Colors.white.withValues(alpha: 0.02),
          Colors.white.withValues(alpha: 0.10),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r - 2));
    canvas.drawCircle(c, r - 2, rim);
  }

  @override
  bool shouldRepaint(_VinylPainter oldDelegate) => false;
}

// ---------------------------------------------------------------- tonearm

class _Tonearm extends StatelessWidget {
  const _Tonearm({required this.size, required this.playing});

  final double size;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final double armLength = size * 0.46;

    final Widget arm = SizedBox(
      width: 40,
      child: Column(
        children: <Widget>[
          // 支点（仿网易云金属圆钮）
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFD8D8DC),
              border: Border.all(color: Colors.black26, width: 2),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF6E6E73),
                ),
              ),
            ),
          ),
          // 针臂（细长渐变杆）
          Container(
            width: 6.5,
            height: armLength,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0xFFCDCDD2), Color(0xFFB4B4BA)],
              ),
            ),
          ),
          // 针头
          Container(
            width: 14,
            height: 24,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: const Color(0xFF101012),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
                width: 1,
              ),
            ),
          ),
        ],
      ),
    );

    // 仿网易云：播放时唱臂顺时针搭向盘面（+14°），
    // 暂停时逆时针抬起（-18°）；旋转轴心在支点
    return AnimatedRotation(
      turns: playing ? 14 / 360 : -18 / 360,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: arm,
    );
  }
}
