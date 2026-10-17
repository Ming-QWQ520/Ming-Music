/// 播放页封面视图：按 NpCoverStyle 渲染三种样式 ——
///  - vinyl：黑胶唱片（VinylDisc，含唱针与旋转）；
///  - square：圆角方形大图（Apple Music 风格）；
///  - circle：圆形大图。
///
/// 附加自定义：缩放（coverScale）与投影（coverShadow）。
library;

import 'package:flutter/material.dart';

import '../../../../core/widgets/cover_image.dart';
import '../../domain/np_settings.dart';
import 'vinyl_disc.dart';

class CoverArtView extends StatelessWidget {
  const CoverArtView({
    super.key,
    required this.style,
    required this.playing,
    required this.size,
    this.cover,
    this.scale = 1.0,
    this.shadow = true,
  });

  final NpCoverStyle style;
  final bool playing;
  final double size;
  final String? cover;
  final double scale;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final double s = size * scale.clamp(0.70, 1.20);

    final Widget child = switch (style) {
      NpCoverStyle.vinyl => VinylDisc(
          cover: cover,
          playing: playing,
          size: s,
        ),
      NpCoverStyle.square => _FlatCover(
          cover: cover,
          size: s * 0.92,
          radius: s * 0.092,
          shadow: shadow,
        ),
      NpCoverStyle.circle => _FlatCover(
          cover: cover,
          size: s * 0.92,
          radius: s * 0.46,
          shadow: shadow,
        ),
    };

    return child;
  }
}

class _FlatCover extends StatelessWidget {
  const _FlatCover({
    required this.cover,
    required this.size,
    required this.radius,
    required this.shadow,
  });

  final String? cover;
  final double size;
  final double radius;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
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
        borderRadius: BorderRadius.circular(radius),
        child: CoverImage(
            src: cover, size: size, radius: radius, coverSize: CoverSize.large),
      ),
    );
  }
}
