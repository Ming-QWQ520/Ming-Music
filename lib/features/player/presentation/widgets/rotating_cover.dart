/// 旋转封面：
///  - RotationTransition + AnimationController，播放时匀速旋转、
///    暂停时**冻结当前角度**（不是反转归零），恢复播放无缝继续；
///  - RepaintBoundary 隔离高频重绘（避坑指南 3）；
///  - 仅订阅 playing 与 currentTrack 两个字段（select 精细监听）；
///  - Hero 与 Mini 播放条联动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../providers/player_providers.dart';

class RotatingCover extends ConsumerStatefulWidget {
  const RotatingCover({super.key});

  @override
  ConsumerState<RotatingCover> createState() => _RotatingCoverState();
}

class _RotatingCoverState extends ConsumerState<RotatingCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppConstants.rotationPeriod,
    );
    // 进入播放页时若正在播放，立即续转
    if (ref.read(playerProvider.select((PlayerState s) => s.playing))) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 精细订阅：只有 track 变化才重建本组件（playing 走 ref.listen）
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool busy = ref.watch(playerProvider.select((PlayerState s) =>
        s.processing == AppProcessingState.loading ||
        s.processing == AppProcessingState.buffering));

    // 平滑的播放/暂停过渡：暂停冻结角度，恢复从原角度继续
    ref.listen<bool>(
      playerProvider.select((PlayerState s) => s.playing),
      (bool? prev, bool next) {
        if (next && !_controller.isAnimating) {
          _controller.forward();
        } else if (!next && _controller.isAnimating) {
          _controller.stop();
        }
      },
    );

    final String? cover = track?.cover;
    final double diameter = _coverDiameter(context);

    return Center(
      child: RepaintBoundary(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: diameter,
              height: diameter,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // 背景光晕
                  Container(
                    width: diameter,
                    height: diameter,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color:
                              AppConstants.brandColor.withValues(alpha: 0.28),
                          blurRadius: 60,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                  ),
                  // 旋转层
                  RotationTransition(
                    turns: _controller,
                    child: Hero(
                      tag: cover ?? 'cover-placeholder',
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        child: SizedBox(
                          key: ValueKey<String>(track?.id ?? 'none'),
                          width: diameter * 0.82,
                          height: diameter * 0.82,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.22),
                                width: 1.4,
                              ),
                              boxShadow: const <BoxShadow>[
                                BoxShadow(
                                  color: Color(0x66000000),
                                  blurRadius: 28,
                                  offset: Offset(0, 12),
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: CoverImage(
                                src: cover,
                                size: diameter * 0.82,
                                radius: diameter,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 黑胶中心孔装饰
                  IgnorePointer(
                    child: Container(
                      width: diameter * 0.09,
                      height: diameter * 0.09,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.55),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                  if (busy)
                    IgnorePointer(
                      child: SizedBox(
                        width: diameter * 0.16,
                        height: diameter * 0.16,
                        child: const CircularProgressIndicator(
                          strokeWidth: 2.4,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white70),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            // 标题与歌手（切歌时滑动过渡）
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> anim) {
                return FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.24),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                );
              },
              child: Column(
                key: ValueKey<String>('meta-${track?.id ?? 'none'}'),
                children: <Widget>[
                  Text(
                    track?.title ?? '未在播放',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${track?.artist ?? ''} · ${track?.album ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: Colors.white.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _coverDiameter(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    final double height = MediaQuery.sizeOf(context).height;
    final bool wide = width >= AppConstants.wideBreakpoint;
    final double base = wide ? width * 0.36 : width * 0.72;
    // clamp 要求 lower <= upper（自由窗口/分屏下 height*0.46 可能小于 180，
    // 直接 clamp(180, …) 会抛 ArgumentError 导致播放页崩溃）
    final double upper =
        wide ? 340.0 : (height * 0.46).clamp(120.0, double.infinity);
    final double lower = upper < 180 ? upper : 180;
    return base.clamp(lower, upper);
  }
}
