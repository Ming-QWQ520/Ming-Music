/// 背景系统渲染端（BackgroundProvider 的 UI 侧）：
///  - 三种背景：动态高斯模糊封面 / 纯色渐变（5 预设）/ 本地图片；
///  - AnimatedSwitcher 平滑切换；
///  - 模糊封面使用 ImageFiltered（对源图模糊）而非全屏 BackdropFilter，
///    严格遵守避坑指南 2 的性能红线；
///  - 渐变光斑用径向渐变模拟，零滤镜成本。
library;

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
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
      BackgroundType.gradient => _GradientBackground(
          preset: kGradientPresets[
              config.gradientIndex.clamp(0, kGradientPresets.length - 1)],
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
          // 无缝换图（旧图保留到新图就绪），背景类型/渐变/自定义图片
          // 变化仍走 AnimatedSwitcher 平滑过渡。
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

// ---------------------------------------------------------------- 渐变

class _GradientBackground extends StatelessWidget {
  const _GradientBackground({required this.preset});

  final GradientPreset preset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[preset.top, preset.bottom],
            ),
          ),
        ),
        // 径向渐变光斑（零滤镜成本）
        Align(
          alignment: const Alignment(0.7, -0.5),
          child: _GlowBlob(
            size: 320,
            color: Colors.white.withValues(alpha: 0.10),
          ),
        ),
        Align(
          alignment: const Alignment(-0.8, 0.55),
          child: _GlowBlob(
            size: 380,
            color: Colors.white.withValues(alpha: 0.07),
          ),
        ),
      ],
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[color, color.withValues(alpha: 0)],
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
      // 图片缺失 → 回退默认渐变
      return _GradientBackground(preset: kGradientPresets[0]);
    }

    final double d = dim.clamp(0.0, 0.85);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              _GradientBackground(preset: kGradientPresets[0]),
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
