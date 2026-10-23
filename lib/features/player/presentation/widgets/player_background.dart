/// 背景系统渲染端（BackgroundProvider 的 UI 侧）：
///  - 三种背景：动态高斯模糊封面 / **流体背景（需求：替代纯色渐变）** / 本地图片；
///  - AnimatedSwitcher 平滑切换；
///  - 模糊封面使用 ImageFiltered（对源图模糊）而非全屏 BackdropFilter，
///    严格遵守避坑指南 2 的性能红线；
///  - 流体背景用多枚径向渐变光斑做 Lissajous 漂移，零滤镜成本（老机型安全）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../../settings/domain/settings_models.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../domain/np_settings.dart';
import '../../providers/np_settings_providers.dart';
import '../../providers/player_providers.dart';

class PlayerBackground extends ConsumerWidget {
  const PlayerBackground({super.key, this.blurFactor = 1, this.dimFactor = 1});

  /// 入场动画系数（0→1）：随全屏播放页打开渐进模糊（Hero + 背景模糊动画）
  final double blurFactor;

  /// 入场动画系数（0→1）：随全屏播放页打开渐进压暗
  final double dimFactor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BackgroundConfig config = ref.watch(backgroundProvider);
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    // 播放页自定义：模糊强度 / 变暗程度（仅对封面模糊与自定义图片背景生效）
    final double bgBlur =
        ref.watch(npSettingsProvider.select((NpPlayerSettings s) => s.bgBlur));
    final double bgDim =
        ref.watch(npSettingsProvider.select((NpPlayerSettings s) => s.bgDim));

    final double f = blurFactor.clamp(0.0, 1.0);
    final double df = dimFactor.clamp(0.0, 1.0);

    final Widget child = switch (config.type) {
      BackgroundType.blurCover => _BlurCoverBackground(
          cover: track?.cover,
          blurSigma: (bgBlur * f).clamp(0, 40),
          dim: (bgDim / 100) * df,
        ),
      BackgroundType.fluid => _FluidBackground(
          dim: (bgDim / 100) * df,
        ),
      BackgroundType.image => _ImageBackground(
          path: config.imagePath,
          dim: (bgDim / 100) * df,
        ),
    };

    return RepaintBoundary(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 650),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (Widget child, Animation<double> anim) =>
            FadeTransition(opacity: anim, child: child),
        layoutBuilder: (Widget? current, List<Widget> previousChildren) =>
            Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ...previousChildren,
            if (current != null) current,
          ],
        ),
        child: Container(
          // 需求「切换歌曲时短暂显示首页」修复：key 不再包含 track.id ——
          // 换歌时不重建背景层（旧实现整层交叉淡化，新图加载期间露出
          // 深色兜底与页面下方路由的叠影，观感像闪回首页）；封面变化由
          // _BlurCoverBackground 内部 CoverImage keepOldWhileLoading
          // 无缝换图（旧图保留到新图就绪），背景类型/自定义图片变化仍走
          // AnimatedSwitcher 平滑过渡。
          key: ValueKey<Object>(config.identityKey),
          color: const Color(0xFF0B0A14),
          child: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 模糊封面

class _BlurCoverBackground extends StatelessWidget {
  const _BlurCoverBackground({
    this.cover,
    this.blurSigma = 46,
    this.dim = 0.42,
  });

  final String? cover;

  /// 模糊半径（播放页自定义滑杆 4 - 40）
  final double blurSigma;

  /// 变暗程度 0 - 1
  final double dim;

  @override
  Widget build(BuildContext context) {
    final double d = dim.clamp(0.0, 0.85);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 对源图做模糊（ImageFiltered），避免全屏 BackdropFilter 的 GPU 开销
        // 入场时 sigma 从 0 渐入（blurFactor 驱动，见 PlayerBackground）
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Transform.scale(
            scale: 1.35, // 放大避免模糊边缘露黑
            // keepOldWhileLoading：切歌时保留旧模糊图直到新图就绪（无缝）
            child: CoverImage(
              src: cover,
              size: 1024,
              radius: 0,
              keepOldWhileLoading: true,
            ),
          ),
        ),
        // 暗色纱罩保证前景可读性（强度可调）
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.black.withValues(alpha: d),
                Colors.black.withValues(alpha: d * 0.7),
                Colors.black.withValues(alpha: (d * 1.35).clamp(0.0, 0.9)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 流体背景

/// 流体背景（需求：播放页去除纯色渐变，增加流体背景）：
///  - 深色底 + 5 枚大尺寸径向渐变光斑，各自沿 Lissajous 轨迹缓慢漂移；
///  - 光斑为 RadialGradient 圆（色→透明），**零滤镜成本**，
///    老机型（Skia/GLES）也能稳 60fps；
///  - 24s 一个循环，相位错开，观感是连续流动的彩色流体而非跳变动画。
class _FluidBackground extends StatefulWidget {
  const _FluidBackground({this.dim = 0.45});

  /// 变暗程度 0 - 1
  final double dim;

  @override
  State<_FluidBackground> createState() => _FluidBackgroundState();
}

class _FluidBackgroundState extends State<_FluidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 光斑配置：颜色 / 基准位置（Alignment） / 漂移幅度 / 速度与相位
  static const List<({Color color, Alignment base, Offset drift, double speed, double phase})>
      _blobs = <({Color color, Alignment base, Offset drift, double speed, double phase})>[
    (
      color: Color(0xFFE2483D), // 品牌红
      base: Alignment(-0.55, -0.55),
      drift: Offset(0.45, 0.30),
      speed: 0.9,
      phase: 0.00,
    ),
    (
      color: Color(0xFF7B4DFF), // 紫
      base: Alignment(0.65, -0.35),
      drift: Offset(0.35, 0.40),
      speed: 0.7,
      phase: 1.35,
    ),
    (
      color: Color(0xFF2E7CF6), // 蓝
      base: Alignment(0.45, 0.60),
      drift: Offset(0.50, 0.28),
      speed: 0.8,
      phase: 2.60,
    ),
    (
      color: Color(0xFF17B8A6), // 青
      base: Alignment(-0.60, 0.55),
      drift: Offset(0.30, 0.42),
      speed: 0.6,
      phase: 4.10,
    ),
    (
      color: Color(0xFFFF8A3D), // 暖橙
      base: Alignment(0.05, 0.05),
      drift: Offset(0.55, 0.50),
      speed: 0.5,
      phase: 5.20,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double d = widget.dim.clamp(0.0, 0.85);
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) {
        final double t = _controller.value;
        final Size size = MediaQuery.sizeOf(context);
        final double base = size.shortestSide;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 深色底（流体需要暗底衬托光斑的流动感）
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0xFF151226), Color(0xFF0B0A14)],
                ),
              ),
            ),
            for (int i = 0; i < _blobs.length; i++)
              Align(
                alignment: Alignment(
                  _blobs[i].base.x +
                      _blobs[i].drift.dx *
                          math.sin(2 * math.pi * (t * _blobs[i].speed + _blobs[i].phase)),
                  _blobs[i].base.y +
                      _blobs[i].drift.dy *
                          math.cos(2 * math.pi * (t * _blobs[i].speed * 0.83 + _blobs[i].phase)),
                ),
                child: _FluidBlob(
                  size: base * (0.62 + 0.10 * i),
                  color: _blobs[i].color.withValues(alpha: 0.30),
                ),
              ),
            // 暗色纱罩保证前景可读性（强度可调）
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: d),
                    Colors.black.withValues(alpha: d * 0.7),
                    Colors.black.withValues(alpha: (d * 1.3).clamp(0.0, 0.9)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 单枚流体光斑：径向渐变圆（色 → 透明），无需 BackdropFilter/ImageFilter
class _FluidBlob extends StatelessWidget {
  const _FluidBlob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: <Color>[color, color.withValues(alpha: 0)],
              stops: const <double>[0.0, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 本地图片

class _ImageBackground extends StatelessWidget {
  const _ImageBackground({this.path, this.dim = 0.45});

  final String? path;

  /// 变暗程度 0 - 1
  final double dim;

  @override
  Widget build(BuildContext context) {
    final String? p = path;
    final File? file = (p != null && File(p).existsSync()) ? File(p) : null;

    if (file == null) {
      // 图片缺失 → 回退流体背景（需求：渐变已移除）
      return const _FluidBackground();
    }

    final double d = dim.clamp(0.0, 0.85);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _FluidBackground(),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.black.withValues(alpha: d),
                Colors.black.withValues(alpha: d * 0.75),
                Colors.black.withValues(alpha: (d * 1.3).clamp(0.0, 0.9)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
