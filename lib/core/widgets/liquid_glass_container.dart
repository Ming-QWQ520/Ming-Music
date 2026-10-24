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

import 'dart:ui' show ImageFilter;

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

/// 条形液态玻璃底板（第十二批需求：Mini 播放条与底部导航栏**共用同一配方**，
/// 视觉完全一致）：
///
///  - 需求①：底板**无色** —— 不再提供颜色/透明度自定义，统一中性玻璃
///    （暗色主题用极淡的深紫黑提底，浅色主题用白色提底，仅用于保证
///    白色前景文字在任何内容上可读，玻璃本体依旧高透明）；
///  - 需求②：底部导航栏使用本组件后与 Mini 条观感一致 —— 同模糊、
///    同圆角、同描边、同投影；
///  - 玻璃关闭/低端机降级：按主题深浅的半透明实底（非纯黑）。
class LiquidGlassBarPanel extends ConsumerWidget {
  const LiquidGlassBarPanel({
    super.key,
    required this.child,
    this.borderRadius = 29,
  });

  final Widget child;

  final double borderRadius;

  /// 高亮描边透明度（玻璃态）
  static const double _kBorderAlpha = 0.10;

  /// 投影透明度（玻璃态）—— 高透明底上投影过重会形成一圈“黑边”，
  /// 第十一批已大幅弱化，本批延续该红线
  static const double _kShadowAlpha = 0.10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool glass = ref.watch(glassEnabledProvider);
    final bool dark = Theme.of(context).brightness == Brightness.dark;

    // 填充：无色中性玻璃 —— 暗色 0xFF14101B@0.26 / 浅色 白@0.38
    //（用户诉求「100% 透明」：旧默认填充 0.35 仍显闷，本批降低到
    // 接近全透，靠 BackdropFilter 模糊保证前景可读）；
    // 降级（玻璃关闭）：按主题深浅的高不透明实底保证可读
    final Color tint = dark ? const Color(0xFF14101B) : Colors.white;
    final double fillAlpha =
        glass ? (dark ? 0.26 : 0.38) : (dark ? 0.90 : 0.96);

    final Widget content = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: tint.withValues(alpha: fillAlpha),
        border: Border.all(
          color: Colors.white.withValues(alpha: _kBorderAlpha),
          width: 0.8,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: _kShadowAlpha),
            blurRadius: 12,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: child,
    );

    if (!glass) return content;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: content,
      ),
    );
  }
}
