/// 统一封面组件：兼容 asset / 网络图 / 占位渐变三种来源。
library;

import 'package:flutter/material.dart';

class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    this.src,
    this.size = 48,
    this.radius = 12,
  });

  /// asset 全路径（assets/...）或 http(s) 网络地址；null 显示占位。
  final String? src;
  final double size;
  final double radius;

  static bool _isNetwork(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    final Widget placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF3A3352), Color(0xFF221E38)],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        size: size * 0.42,
        color: Colors.white.withValues(alpha: 0.5),
      ),
    );

    final String? source = src;
    Widget image = placeholder;
    if (source != null && source.isNotEmpty) {
      if (_isNetwork(source)) {
        image = Image.network(
          source,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => placeholder,
        );
      } else {
        image = Image.asset(
          source,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => placeholder,
        );
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: image,
    );
  }
}
