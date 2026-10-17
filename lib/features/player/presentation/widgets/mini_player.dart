/// Mini 播放条（参考图1/2 底部胶囊样式）：
///  - 圆角胶囊 + 局部液态玻璃材质（LiquidGlassContainer）；
///  - 单行：圆角封面 + 「歌名 - 歌手」 + 播放按钮 + 播放列表按钮；
///  - 进度条：播放按钮四周的圆环（顶部中心为起点，顺时针），
///    替代旧版底部细线（需求）；
///  - 点击主体进入全屏播放页（上滑转场）；
///  - `select` 只订阅 playing / currentTrack / hasQueue，
///    圆环独立成 RepaintBoundary 隔离的子组件（避坑指南 3）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../../core/widgets/liquid_glass_container.dart';
import '../../../library/domain/track.dart';
import '../../providers/player_providers.dart';
import '../full_player_page.dart';
import 'queue_sheet.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool hasQueue = ref.watch(hasQueueProvider);
    if (!hasQueue) return const SizedBox.shrink();

    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: LiquidGlassContainer(
        borderRadius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        onTap: () => openFullPlayer(context),
        child: Row(
          children: <Widget>[
            // Hero：与全屏播放页封面联动
            Hero(
              tag: _heroTag(cover),
              child: CoverImage(src: cover, size: 40, radius: 20),
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

/// 封面 Hero 标签（Mini 与全屏页共用；无封面时用固定 tag）
String _heroTag(String? cover) => cover ?? 'cover-placeholder';

/// 播放按钮四周的圆环进度：顶部中心为起点，顺时针（需求指定样式）。
/// RepaintBoundary 隔离，只订阅 position/duration 两个流。
class _MiniRingProgress extends ConsumerWidget {
  const _MiniRingProgress();

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
        painter: _RingPainter(progress),
        size: const Size(48, 48),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 2.4;
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
      oldDelegate.progress != progress;
}

// ---------------------------------------------------------------- buttons

class _MiniPlayButton extends ConsumerWidget {
  const _MiniPlayButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    final bool busy = ref.watch(playerProvider.select((PlayerState s) =>
        s.processing == AppProcessingState.loading ||
        s.processing == AppProcessingState.buffering));

    // 圆环进度包裹播放按钮（顶部中心为起点），环层在按钮之下
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          const Positioned.fill(child: _MiniRingProgress()),
          SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              onPressed: () => ref.read(playerProvider.notifier).playPause(),
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        key: ValueKey<bool>(playing),
                        size: 24,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniQueueButton extends ConsumerWidget {
  const _MiniQueueButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        onPressed: () => showQueueSheet(context),
        icon: const Icon(Icons.queue_music_rounded, size: 24),
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
