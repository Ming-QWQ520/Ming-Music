/// 统一底部弹窗宿主（液态玻璃 + Navigator 崩溃修复）。
///
/// ⚠️ 崩溃修复（logcat 实证，run: showQueueSheet → Navigator.of 空指针）：
/// `showModalBottomSheet` 内部执行 `Navigator.of(context)`，若调用点的
/// context 不在 Navigator 之下（如经由 `MaterialApp.builder` 构建的
/// 全局 Mini 播放条 / 全屏播放页个别浮层），空检查直接抛
/// `Null check operator used on a null value`。
/// 本宿主优先取全局 [rootNavigatorKey]（MaterialApp.router 上的
/// NavigatorState，恒可用），context 查找仅作兜底 —— 任何上下文都能安全弹窗。
///
/// 液态玻璃（需求：全面重构 UI 增加液态玻璃）：
/// 弹窗底板统一 [GlassSheet] —— 半透明深色底 + BackdropFilter 模糊 +
/// 顶部描边高光；低端机/关闭液态玻璃时自动降级为不透明深色底。
/// （性能红线：BackdropFilter 仅允许 Mini 播放条与底部 Sheet 使用。）
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/providers/settings_providers.dart';
import '../router.dart' show rootNavigatorKey;

/// 统一底部弹窗入口：永不因 context 查找失败而抛异常。
///
/// [isScrollControlled] / [useSafeArea] / [barrierLabel] 语义与
/// showModalBottomSheet 一致。
Future<T?> showMingSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = true,
  bool isDismissible = true,
  String barrierLabel = 'MingMusic sheet',
}) {
  final NavigatorState? nav = rootNavigatorKey.currentState ??
      Navigator.maybeOf(context, rootNavigator: true);
  // 理论上 rootNavigatorKey 恒非空（MaterialApp.router 挂载）；双保险：
  // 万一极早期调用（Navigator 未挂载）静默放弃，绝不抛异常打断播放流程。
  if (nav == null) {
    debugPrint('showMingSheet: root navigator not ready, skip');
    return Future<T?>.value();
  }
  return nav.push<T>(
    ModalBottomSheetRoute<T>(
      builder: builder,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      isDismissible: isDismissible,
      enableDrag: isDismissible,
      barrierLabel: barrierLabel,
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
  );
}

/// 液态玻璃弹窗底板：所有底部 Sheet 的统一容器。
class GlassSheet extends ConsumerWidget {
  const GlassSheet({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.maxHeight,
    this.padding = EdgeInsets.zero,
    this.blurSigma = 22,
  });

  final Widget child;
  final double borderRadius;

  /// 限高（一般传屏幕高度百分比）；null = 包裹内容
  final double? maxHeight;
  final EdgeInsetsGeometry padding;
  final double blurSigma;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool glass = ref.watch(glassEnabledProvider);

    final Widget content = Padding(
      padding: padding,
      child: child,
    );

    Widget panel = glass
        ? ClipRRect(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(borderRadius)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: _paint(content, glass: true),
            ),
          )
        : _paint(content, glass: false);

    if (maxHeight != null) {
      panel = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight!),
        child: panel,
      );
    }
    return panel;
  }

  Widget _paint(Widget child, {required bool glass}) {
    return Container(
      decoration: BoxDecoration(
        color: glass
            ? const Color(0xD9131018) // 玻璃态：更通透的深色
            : AppSheetColors.fallback, // 降级：不透明深色
        borderRadius: BorderRadius.vertical(top: Radius.circular(borderRadius)),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: glass ? 0.16 : 0.10),
            width: 1,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// 弹窗配色集中管理（Sheet 内 ListTile / 文案统一引用）
class AppSheetColors {
  AppSheetColors._();

  /// 液态玻璃降级底色
  static const Color fallback = Color(0xFF18141F);
}
