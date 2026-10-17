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
import '../../providers/player_providers.dart';

class PlayerBackground extends ConsumerWidget {
  const PlayerBackground({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BackgroundConfig config = ref.watch(backgroundProvider);
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));

    final Widget child = switch (config.type) {
      BackgroundType.blurCover => _BlurCoverBackground(cover: track?.cover),
      BackgroundType.gradient => _GradientBackground(
          preset: kGradientPresets[
              config.gradientIndex.clamp(0, kGradientPresets.length - 1)],
        ),
      BackgroundType.image => _ImageBackground(path: config.imagePath),
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
          key: ValueKey<Object>('${config.identityKey}|${track?.id ?? 'none'}'),
          color: const Color(0xFF0B0A14),
          child: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 模糊封面

class _BlurCoverBackground extends StatelessWidget {
  const _BlurCoverBackground({this.cover});

  final String? cover;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 对源图做模糊（ImageFiltered），避免全屏 BackdropFilter 的 GPU 开销
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 46, sigmaY: 46),
          child: Transform.scale(
            scale: 1.35, // 放大避免模糊边缘露黑
            child: CoverImage(src: cover, size: 1024, radius: 0),
          ),
        ),
        // 暗色纱罩保证前景可读性
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.black.withValues(alpha: 0.42),
                Colors.black.withValues(alpha: 0.30),
                Colors.black.withValues(alpha: 0.58),
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
  const _ImageBackground({this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final String? p = path;
    final File? file = (p != null && File(p).existsSync()) ? File(p) : null;

    if (file == null) {
      // 图片缺失 → 回退默认渐变
      return _GradientBackground(preset: kGradientPresets[0]);
    }

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
                Colors.black.withValues(alpha: 0.46),
                Colors.black.withValues(alpha: 0.34),
                Colors.black.withValues(alpha: 0.60),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
