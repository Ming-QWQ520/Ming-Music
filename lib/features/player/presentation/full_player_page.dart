/// 全屏播放页（响应式）：
///
///  - 手机（<600dp）：单列 = 状态栏 → 封面 → 高亮歌词 → 进度条 → 控制；
///  - 平板（>=600dp）：双列 = 左（封面 + 进度 + 控制）/ 右（滚动歌词 + 详情）；
///  - 手势（避坑指南 4）：
///      · 左右滑动切歌，但避开屏幕左右边缘 20px（让位系统侧滑返回）；
///      · 下滑超过阈值或高速下甩 → 收起播放页；
///  - 自定义上滑/下滑转场路由（FullPlayerRoute），与 Mini 播放条 Hero 联动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../providers/player_providers.dart';
import 'widgets/full_player_widgets.dart';
import 'widgets/module_stack.dart';
import 'widgets/player_background.dart';
import 'widgets/player_detail_sheet.dart';

/// 自定义转场路由：上滑进入、下滑退出，沉浸背景（opaque 保证性能）
class FullPlayerRoute<T> extends PageRouteBuilder<T> {
  FullPlayerRoute()
      : super(
          transitionDuration: const Duration(milliseconds: 360),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (BuildContext context, Animation<double> animation,
                  Animation<double> secondaryAnimation) =>
              const FullPlayerPage(),
          transitionsBuilder: (BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child) {
            final Animation<double> curved =
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(curved),
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.4, end: 1).animate(curved),
                child: child,
              ),
            );
          },
        );
}

class FullPlayerPage extends ConsumerStatefulWidget {
  const FullPlayerPage({super.key});

  @override
  ConsumerState<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends ConsumerState<FullPlayerPage> {
  bool _edgeBlocked = false;
  double _dragDy = 0;

  // ---------------------------------------------------------------- gestures

  void _onHorizontalDragStart(DragStartDetails details) {
    final double width = MediaQuery.sizeOf(context).width;
    final double dx = details.localPosition.dx;
    // 边缘 20px 让位系统侧滑返回（避坑指南 4）
    _edgeBlocked = dx < AppConstants.gestureEdgeExclusion ||
        dx > width - AppConstants.gestureEdgeExclusion;
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_edgeBlocked) return;
    final double vx = details.velocity.pixelsPerSecond.dx;
    if (vx < -AppConstants.dismissVelocityThreshold * 0.7) {
      ref.read(playerProvider.notifier).next(); // 左滑 → 下一首
    } else if (vx > AppConstants.dismissVelocityThreshold * 0.7) {
      ref.read(playerProvider.notifier).previous(); // 右滑 → 上一首
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (details.delta.dy > 0) _dragDy += details.delta.dy;
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final double vy = details.velocity.pixelsPerSecond.dy;
    final bool shouldDismiss = _dragDy > AppConstants.dismissDragThreshold ||
        vy > AppConstants.dismissVelocityThreshold;
    _dragDy = 0;
    if (shouldDismiss && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideBreakpoint;

    // 播放错误提示（监听而非 watch，避免 rebuild 风暴）
    ref.listen<String?>(playerProvider.select((PlayerState s) => s.error),
        (String? prev, String? next) {
      if (next != null && next.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next)),
        );
        ref.read(playerProvider.notifier).clearError();
      }
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _onHorizontalDragStart,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const PlayerBackground(),
            SafeArea(
              child: Column(
                children: <Widget>[
                  PlayerTopBar(onDetail: () => showPlayerDetailSheet(context)),
                  Expanded(
                    child: isWide
                        ? TabletPlayerBody(
                            onDetail: () => showPlayerDetailSheet(context))
                        : const PlayerModuleStack(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
