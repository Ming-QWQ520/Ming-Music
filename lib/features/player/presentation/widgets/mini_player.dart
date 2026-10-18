/// Mini 播放条（需求改造：无边框透明 + 多套组件布局不同的样式）：
///
/// 样式（NpPlayerSettings.miniStyle，播放页自定义面板可切换）：
///  - classic 经典条：封面左 + 「歌名 - 歌手」 + 圆环播放键 + 播放列表键；
///  - overlay 封面铺满：封面作条背景 + 渐变压暗，文字压在封面上；
///  - compact 紧凑极简：仅封面 + 圆环绕封面 + 小播放键，无文字；
///  - wide 宽幅双行：大封面 + 歌名/歌手双行 + 底部细进度线。
///
/// 通用：
///  - 无边框、无底色（透明，由页面背景透出）；
///  - 进度：播放键四周圆环（顶部中心起点，顺时针）；
///  - 点击主体进入全屏播放页（上滑转场）；
///  - `select` 只订阅 playing / currentTrack / hasQueue，
///    圆环独立成 RepaintBoundary 隔离的子组件（避坑指南 3）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../domain/np_settings.dart';
import '../../providers/np_settings_providers.dart';
import '../../providers/player_providers.dart';
import '../full_player_page.dart';
import 'queue_sheet.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool hasQueue = ref.watch(hasQueueProvider);
    if (!hasQueue) return const SizedBox.shrink();

    final MiniPlayerStyle style = ref.watch(
        npSettingsProvider.select((NpPlayerSettings s) => s.miniStyle));

    return switch (style) {
      MiniPlayerStyle.classic => const _ClassicMini(),
      MiniPlayerStyle.overlay => const _OverlayMini(),
      MiniPlayerStyle.compact => const _CompactMini(),
      MiniPlayerStyle.wide => const _WideMini(),
    };
  }
}

/// 封面 Hero 标签（Mini 与全屏页共用；无封面时用固定 tag）
String _heroTag(String? cover) => cover ?? 'cover-placeholder';

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

// ---------------------------------------------------------------- 播放键

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

// ---------------------------------------------------------------- 样式 1：经典条

/// 封面左 + 文字 + 圆环播放键 + 播放列表（透明无边框）
class _ClassicMini extends ConsumerWidget {
  const _ClassicMini();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: GestureDetector(
        onTap: () => openFullPlayer(context),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: <Widget>[
            Hero(
              tag: _heroTag(cover),
              child: CoverImage(src: cover, size: 40, radius: 8),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                track == null ? '未在播放' : '${track.title} - ${track.artist}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const _MiniPlayButton(),
            const _MiniQueueButton(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 样式 2：封面铺满

/// 封面作条背景 + 底部渐变压暗，文字压在封面上（网易云桌面端风格）
class _OverlayMini extends ConsumerWidget {
  const _OverlayMini();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: GestureDetector(
        onTap: () => openFullPlayer(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 54,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // 封面铺满背景
                Hero(
                  tag: _heroTag(cover),
                  child: CoverImage(
                      src: cover, size: 300, radius: 0, coverSize: CoverSize.large),
                ),
                // 渐变压暗保证文字可读
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: <Color>[
                        Color(0xB3000000),
                        Color(0x59000000),
                        Color(0x8C000000),
                      ],
                    ),
                  ),
                ),
                // 文字 + 控制键
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              track?.title ?? '未在播放',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              track?.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.72),
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const _MiniPlayButton(size: 40, iconSize: 22),
                      const _MiniQueueButton(size: 38, iconSize: 21),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 样式 3：紧凑极简

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
                    tag: _heroTag(cover),
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

// ---------------------------------------------------------------- 样式 4：宽幅双行

/// 大封面 + 歌名/歌手双行 + 右侧控制 + 底部细进度线
class _WideMini extends ConsumerWidget {
  const _WideMini();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: GestureDetector(
        onTap: () => openFullPlayer(context),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Hero(
                  tag: _heroTag(cover),
                  child: CoverImage(src: cover, size: 48, radius: 10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        track?.title ?? '未在播放',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const _MiniPlayButton(size: 42, iconSize: 23, showRing: false),
                const _MiniQueueButton(size: 38, iconSize: 22),
              ],
            ),
            const SizedBox(height: 6),
            // 底部细进度线（替代旧版条底细线的形态）
            const SizedBox(
              height: 2,
              child: ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(1)),
                child: _MiniLinearProgress(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniLinearProgress extends ConsumerWidget {
  const _MiniLinearProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double position =
        ref.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double duration =
        ref.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 1;
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
  }
}

/// 供播放页路由使用：打开全屏播放页（自定义上滑转场 + Hero 联动）
Future<void> openFullPlayer(BuildContext context) {
  return Navigator.of(context).push<void>(
    FullPlayerRoute<void>(),
  );
}
