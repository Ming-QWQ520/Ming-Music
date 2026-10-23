/// 液态玻璃容器（Glassmorphism 封装）。
///
/// ⚠️ 避坑指南 2 —— 性能深坑：
/// `BackdropFilter` 极度消耗 GPU，本组件**只允许**用于：
///   1. Mini 播放条
///   2. 底部弹出的详情 Sheet
/// 严禁在整页背景上使用。
///
/// 降级策略：
///   - glassEnabledProvider 为 false 时自动切换为纯半透明背景，
///     不创建任何 BackdropFilter 层；
///   - 低端机（Android 12 以下）由 deviceGlassCapableProvider 自动降级。
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/providers/settings_providers.dart';

class LiquidGlassContainer extends ConsumerWidget {
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.margin,
    this.blurSigma = 18,
    this.onTap,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final double blurSigma;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool glass = ref.watch(glassEnabledProvider);

    final Widget content = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: glass
              ? <Color>[
                  Colors.white.withValues(alpha: 0.14),
                  Colors.white.withValues(alpha: 0.04),
                ]
              : <Color>[
                  Colors.white.withValues(alpha: 0.10),
                  Colors.white.withValues(alpha: 0.06),
                ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: glass ? 0.20 : 0.12),
          width: 1,
        ),
      ),
      child: Padding(padding: padding, child: child),
    );

    Widget result = glass
        ? ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.02),
                ),
                child: content,
              ),
            ),
          )
        // 降级：纯半透明背景，零 GPU 滤镜
        : Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              color: const Color(0xCC16121F),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: content,
          );

    if (margin != null) {
      result = Padding(padding: margin!, child: result);
    }
    if (onTap != null) {
      result = GestureDetector(onTap: onTap, child: result);
    }
    return result;
  }
}
