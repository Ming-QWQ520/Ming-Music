/// 播放页封面视图：按 NpCoverStyle 渲染两种样式 ——
///  - square：方形大图（默认无圆角，可设置开启圆角；Apple Music 风格）；
///  - circle：圆形大图。
///（需求：黑胶样式已移除）
///
/// 附加自定义：缩放（coverScale）与投影（coverShadow）。
///
/// 方形样式动态（需求加大幅度）：
///  - 播放时封面保持完整尺寸（scale 1.0）；
///  - 暂停时明显缩小（AnimatedScale 平滑过渡）；
///
/// Hero（需求）：与 Mini 播放条同 tag —— 路由转场时封面从底部无缝放大。
library;

import 'package:flutter/material.dart';

import '../../../../core/widgets/cover_image.dart';
import '../../domain/np_settings.dart';
import 'mini_player.dart' show heroTagOf;

class CoverArtView extends StatelessWidget {
  const CoverArtView({
    super.key,
    required this.style,
    required this.playing,
    required this.size,
    this.cover,
    this.scale = 1.0,
    this.shadow = true,
    this.squareRadius = false,
    this.onLongPress,
    this.hero = true,
  });

  final NpCoverStyle style;
  final bool playing;
  final double size;
  final String? cover;
  final double scale;
  final bool shadow;

  /// 方形封面圆角开关（默认无圆角，自定义开启）
  final bool squareRadius;

  /// 长按封面 → 全屏查看 + 保存（需求）
  final VoidCallback? onLongPress;

  /// 是否包 Hero（列表轮播中同封面出现多份时无需关；默认开）
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final double s = size * scale.clamp(0.70, 1.20);

    Widget child = switch (style) {
      NpCoverStyle.square => _FlatCover(
          cover: cover,
          // 需求：播放时尺寸不变，暂停时明显缩小
          size: s * 0.92,
          radius: squareRadius ? s * 0.055 : 0,
          shadow: shadow,
          shrinkOnPause: true,
          playing: playing,
        ),
      NpCoverStyle.circle => _FlatCover(
          cover: cover,
          size: s * 0.92,
          radius: s * 0.46,
          shadow: shadow,
          playing: playing,
        ),
    };

    if (hero) {
      child = Hero(
        tag: heroTagOf(cover),
        child: child,
      );
    }

    if (onLongPress == null) return child;
    return GestureDetector(
      onLongPress: onLongPress,
      child: child,
    );
  }
}

class _FlatCover extends StatelessWidget {
  const _FlatCover({
    required this.cover,
    required this.size,
    required this.radius,
    required this.shadow,
    required this.playing,
    this.shrinkOnPause = false,
  });

  final String? cover;
  final double size;
  final double radius;
  final bool shadow;
  final bool playing;

  /// 方形样式专属：暂停时缩小（需求：加大幅度 → scale 0.90）
  final bool shrinkOnPause;

  @override
  Widget build(BuildContext context) {
    final double effRadius = radius.clamp(0.0, size / 2);

    final Widget content = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius:
            effRadius > 0 ? BorderRadius.circular(effRadius) : null,
        boxShadow: shadow
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius:
            effRadius > 0 ? BorderRadius.circular(effRadius) : BorderRadius.zero,
        child: CoverImage(
            src: cover, size: size, radius: 0, coverSize: CoverSize.large),
      ),
    );

    if (!shrinkOnPause) return content;
    // 需求：暂停时明显缩小（播放 scale 1.0 ↔ 暂停 scale 0.90）
    return AnimatedScale(
      scale: playing ? 1.0 : 0.90,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: content,
    );
  }
}
