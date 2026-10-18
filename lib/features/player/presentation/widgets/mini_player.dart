/// Mini 播放条（需求改造）：
///
/// 布局模式（NpPlayerSettings.miniStyle）：
///  - compact 紧凑极简：悬浮条（导航栏上方）—— 圆环绕封面 + 播放键 + 列表键；
///  - classic / overlay / wide：嵌入底部导航栏「发现 ⇄ 我的」中间（需求），
///    不带任何控制键，点击主体进入全屏播放页；三种样式的组件布局各不相同：
///    · classic：封面+圆环 + 单行「歌名 - 歌手」；
///    · overlay：封面作整块背景 + 渐变压暗 + 标题/歌手叠印；
///    · wide：封面+圆环 + 歌名/歌手双行 + 底部细进度线。
///
/// 通用：
///  - 无边框、无底色（透明，仅 compact 自身也是透明悬浮）；
///  - 进度：播放键四周圆环（顶部中心起点，顺时针）；
///  - `select` 只订阅 playing / currentTrack / hasQueue；
///  - 封面 Hero：与全屏播放页同 tag，路由转场无缝放大（配合背景模糊动画）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/router.dart' show openFullPlayer;
import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../domain/np_settings.dart';
import '../../providers/np_settings_providers.dart';
import '../../providers/player_providers.dart';
import 'queue_sheet.dart';

/// 主骨架用：当前样式是否嵌入底部导航栏（非紧凑极简都嵌入）
bool miniInNavBar(MiniPlayerStyle style) => style != MiniPlayerStyle.compact;

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key, this.embedded = false});

  /// true = 渲染为导航栏中央形态（无控制键）；false = 悬浮完整条
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool hasQueue = ref.watch(hasQueueProvider);
    if (!hasQueue) return const SizedBox.shrink();

    final MiniPlayerStyle style = ref.watch(
        npSettingsProvider.select((NpPlayerSettings s) => s.miniStyle));

    if (embedded) {
      return switch (style) {
        MiniPlayerStyle.classic => const _NavClassic(),
        MiniPlayerStyle.overlay => const _NavOverlay(),
        MiniPlayerStyle.wide => const _NavWide(),
        MiniPlayerStyle.compact => const _NavClassic(),
      };
    }
    // 悬浮条仅 compact 使用；其余样式在导航栏模式下不会走到这里
    return switch (style) {
      MiniPlayerStyle.compact => const _CompactMini(),
      _ => const _NavClassic(),
    };
  }
}

/// 封面 Hero 标签（Mini 与全屏页共用；无封面时用固定 tag）
String heroTagOf(String? cover) => cover ?? 'cover-placeholder';

// ---------------------------------------------------------------- 圆环进度

/// 播放键四周的圆环进度：顶部中心为起点，顺时针。
/// RepaintBoundary 隔离，只订阅 position/duration 两个流。
class _MiniRingProgress extends ConsumerWidget {
  const _MiniRingProgress({this.stroke = 2.4});

  final double stroke;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double position =
        ref.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double duration =
        ref.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 1;
    final double progress =
        duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _RingPainter(progress, stroke: stroke),
        size: const Size(48, 48),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.progress, {required this.stroke});

  final double progress;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = (size.shortestSide - stroke) / 2;

    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    // 底环
    final Paint bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withValues(alpha: 0.16);
    canvas.drawArc(rect, 0, math.pi * 2, false, bg);

    // 进度弧：顶部中心（-90°）起始，顺时针
    final Paint fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = AppConstants.brandColor;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, fg);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.stroke != stroke;
}

// ---------------------------------------------------------------- 悬浮：紧凑极简

/// 仅封面（圆环进度绕封面）+ 小播放键 + 列表键，无文字
class _CompactMini extends ConsumerWidget {
  const _CompactMini();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          GestureDetector(
            onTap: () => openFullPlayer(context),
            child: SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  const Positioned.fill(child: _MiniRingProgress(stroke: 2.2)),
                  Hero(
                    tag: heroTagOf(cover),
                    child: CoverImage(src: cover, size: 42, radius: 21),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          const _MiniPlayButton(size: 42, iconSize: 24, showRing: false),
          const _MiniQueueButton(size: 38, iconSize: 22),
        ],
      ),
    );
  }
}

class _MiniPlayButton extends ConsumerWidget {
  const _MiniPlayButton({
    this.size = 48,
    this.iconSize = 24,
    this.showRing = true,
  });

  final double size;
  final double iconSize;
  final bool showRing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    final bool busy = ref.watch(playerProvider.select((PlayerState s) =>
        s.processing == AppProcessingState.loading ||
        s.processing == AppProcessingState.buffering));

    final Widget button = SizedBox(
      width: size,
      height: size,
      child: IconButton(
        padding: EdgeInsets.zero,
        onPressed: () => ref.read(playerProvider.notifier).playPause(),
        icon: busy
            ? SizedBox(
                width: iconSize * 0.7,
                height: iconSize * 0.7,
                child: const CircularProgressIndicator(strokeWidth: 2.2),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  key: ValueKey<bool>(playing),
                  size: iconSize,
                ),
              ),
      ),
    );

    if (!showRing) return button;
    return SizedBox(
      width: size + 8,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: const _MiniRingProgress(),
            ),
          ),
          button,
        ],
      ),
    );
  }
}

class _MiniQueueButton extends ConsumerWidget {
  const _MiniQueueButton({this.size = 40, this.iconSize = 24});

  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        padding: EdgeInsets.zero,
        onPressed: () => showQueueSheet(context),
        icon: Icon(Icons.queue_music_rounded, size: iconSize),
      ),
    );
  }
}

// ---------------------------------------------------------------- 导航栏中央形态

/// 封面（Hero）+ 圆环进度，供各导航样式复用
class _NavCover extends ConsumerWidget {
  const _NavCover({this.size = 46});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    final Widget image = Hero(
      tag: heroTagOf(cover),
      child: CoverImage(src: cover, size: size, radius: size / 2),
    );

    return SizedBox(
      width: size + 8,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: _MiniRingProgress(stroke: 2.2),
            ),
          ),
          image,
        ],
      ),
    );
  }
}

/// 切歌时内容淡入刷新（flutter_animate）
Widget _navAnimated(Widget child, Object key) => child
    .animate(key: ValueKey<Object>(key))
    .fadeIn(duration: 260.ms, curve: Curves.easeOut)
    .slideY(begin: 0.05, end: 0, duration: 260.ms, curve: Curves.easeOut);

/// 样式 1（导航版）：封面+圆环 + 单行「歌名 - 歌手」
class _NavClassic extends ConsumerWidget {
  const _NavClassic();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openFullPlayer(context),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const _NavCover(),
          const SizedBox(width: 8),
          Flexible(
            child: _navAnimated(
              Text(
                track == null ? '未在播放' : '${track.title} - ${track.artist}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
              track?.id ?? 'empty',
            ),
          ),
        ],
      ),
    );
  }
}

/// 样式 2（导航版）：封面整块铺满（圆形裁剪）+ 渐变压暗 + 标题叠印
class _NavOverlay extends ConsumerWidget {
  const _NavOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openFullPlayer(context),
      child: _navAnimated(
        ClipOval(
          child: SizedBox(
            width: 52,
            height: 52,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Hero(
                  tag: heroTagOf(cover),
                  child: CoverImage(src: cover, size: 52, radius: 0),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x59000000), Color(0xCC000000)],
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      track?.title ?? '未在播放',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        track?.id ?? 'empty',
      ),
    );
  }
}

/// 样式 3（导航版）：封面+圆环 + 歌名/歌手双行 + 底部细进度线
class _NavWide extends ConsumerWidget {
  const _NavWide();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openFullPlayer(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const _NavCover(size: 40),
              const SizedBox(width: 8),
              Flexible(
                child: _navAnimated(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        track?.title ?? '未在播放',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        track?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                  track?.id ?? 'empty',
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          SizedBox(
            width: 96,
            height: 2,
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(1)),
              child: Consumer(
                builder: (BuildContext ctx, WidgetRef r, _) {
                  final double position =
                      r.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
                  final double duration =
                      r.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 1;
                  final double progress =
                      duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
                  return RepaintBoundary(
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 2,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      color: AppConstants.brandColor,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
