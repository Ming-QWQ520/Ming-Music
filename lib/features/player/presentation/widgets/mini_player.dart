/// Mini 播放条（参考图1/2 底部胶囊样式）：
///  - 圆角胶囊 + 局部液态玻璃材质（LiquidGlassContainer）；
///  - 单行：圆角封面 + 「歌名 - 歌手」 + 播放按钮 + 播放列表按钮；
///  - 点击主体进入全屏播放页（上滑转场）；
///  - `select` 只订阅 playing / currentTrack / hasQueue，
///    进度线独立成 RepaintBoundary 隔离的子组件（避坑指南 3）。
library;

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
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
            const SizedBox(height: 5),
            const _MiniProgressLine(),
          ],
        ),
      ),
    );
  }
}

/// 封面 Hero 标签（Mini 与全屏页共用；无封面时用固定 tag）
String _heroTag(String? cover) => cover ?? 'cover-placeholder';

/// 底部细进度线：RepaintBoundary 隔离，只订阅 position/duration 两个流
/// （约 200ms 重建一次，影响范围仅这 2px 高的线条）
class _MiniProgressLine extends ConsumerWidget {
  const _MiniProgressLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double position =
        ref.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double duration =
        ref.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 1;
    final double progress =
        duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 2,
          backgroundColor: Colors.white.withValues(alpha: 0.12),
          valueColor:
              const AlwaysStoppedAnimation<Color>(AppConstants.brandColor),
        ),
      ),
    );
  }
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

    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        style: IconButton.styleFrom(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
        ),
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
