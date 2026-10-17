/// 播放控制栏：洗牌 | 上一首 | 播放/暂停 | 下一首 | 循环模式。
/// 各按钮通过 select 只订阅自己关心的状态位。
library;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_providers.dart';

class PlayerControlBar extends ConsumerWidget {
  const PlayerControlBar({super.key, this.iconScale = 1.0});

  /// 平板端可放大
  final double iconScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerNotifier notifier = ref.read(playerProvider.notifier);

    return RepaintBoundary(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const _ShuffleButton(),
          IconButton(
            onPressed: notifier.previous,
            iconSize: 30 * iconScale,
            color: Colors.white.withValues(alpha: 0.88),
            icon: const Icon(Icons.skip_previous_rounded),
          ),
          const _PlayPauseButton(),
          IconButton(
            onPressed: notifier.next,
            iconSize: 30 * iconScale,
            color: Colors.white.withValues(alpha: 0.88),
            icon: const Icon(Icons.skip_next_rounded),
          ),
          const _RepeatButton(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- buttons

class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    final bool busy = ref.watch(playerProvider.select((PlayerState s) =>
        s.processing == AppProcessingState.loading ||
        s.processing == AppProcessingState.buffering));

    return GestureDetector(
      onTap: () => ref.read(playerProvider.notifier).playPause(),
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF9D8CFF), Color(0xFF6C4DF6)],
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0xFF7C5CFF).withValues(alpha: 0.45),
              blurRadius: 26,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey<bool>(playing),
                    size: 38,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ShuffleButton extends ConsumerWidget {
  const _ShuffleButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool shuffle =
        ref.watch(playerProvider.select((PlayerState s) => s.shuffle));
    return IconButton(
      onPressed: () => ref.read(playerProvider.notifier).toggleShuffle(),
      icon: Icon(
        Icons.shuffle_rounded,
        size: 24,
        color: shuffle ? Colors.white : Colors.white.withValues(alpha: 0.55),
      ),
    );
  }
}

class _RepeatButton extends ConsumerWidget {
  const _RepeatButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RepeatMode repeat =
        ref.watch(playerProvider.select((PlayerState s) => s.repeat));
    final Color activeColor = Colors.white;
    final Color idleColor = Colors.white.withValues(alpha: 0.55);

    return IconButton(
      onPressed: () => ref.read(playerProvider.notifier).cycleRepeat(),
      icon: switch (repeat) {
        RepeatMode.one =>
          Icon(Icons.repeat_one_rounded, size: 24, color: activeColor),
        RepeatMode.all =>
          Icon(Icons.repeat_rounded, size: 24, color: activeColor),
        RepeatMode.off =>
          Icon(Icons.repeat_rounded, size: 24, color: idleColor),
      },
    );
  }
}
