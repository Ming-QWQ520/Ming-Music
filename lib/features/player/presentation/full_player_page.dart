/// 全屏播放页（参考图3 网易云黑胶风格）：
///
///  - 上半区：黑胶唱片（播放旋转/暂停停转）⇄ 逐字歌词页（点击黑胶切换）；
///  - 下半区（固定）：歌名+VIP / 歌手 / 红心 → 进度条 → 五键控制栏 →
///    底部音质徽章 + 歌词切换；
///  - 手势：下滑收起播放页；左右滑动切歌（避开边缘 20px，避坑指南 4）；
///  - 平板（>=600dp）：双列 = 左（黑胶 + 控制）/ 右（歌词）。
library;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../library/domain/track.dart';
import '../../library/providers/library_providers.dart';
import '../../settings/domain/settings_models.dart' show AudioQuality;
import '../../settings/providers/settings_providers.dart'
    show audioQualityProvider;
import '../providers/player_providers.dart';
import 'widgets/karaoke_lyrics_view.dart';
import 'widgets/player_background.dart';
import 'widgets/progress_bar.dart';
import 'widgets/queue_sheet.dart';
import 'widgets/vinyl_disc.dart';

/// 自定义转场路由：上滑进入、下滑退出，沉浸背景
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
  bool _showLyrics = false;
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

  void _toggleLyricsPage() {
    setState(() => _showLyrics = !_showLyrics);
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
              child: isWide
                  ? _TabletBody()
                  : _PhoneBody(
                      showLyrics: _showLyrics,
                      onToggleLyrics: _toggleLyricsPage,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 手机

class _PhoneBody extends ConsumerWidget {
  const _PhoneBody({
    required this.showLyrics,
    required this.onToggleLyrics,
  });

  final bool showLyrics;
  final VoidCallback onToggleLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));

    return Column(
      children: <Widget>[
        const _TopBar(),
        // 上半区：黑胶 ⇄ 歌词
        Expanded(
          child: AnimatedSwitcher(
            duration: AppConstants.playerPageFlip,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> anim) =>
                FadeTransition(opacity: anim, child: child),
            child: showLyrics
                ? const SizedBox(
                    key: ValueKey<String>('lyrics'),
                    width: double.infinity,
                    child: KaraokeLyricsView(),
                  )
                : Container(
                    key: const ValueKey<String>('vinyl'),
                    alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: onToggleLyrics,
                      child: VinylDisc(
                        cover: track?.cover,
                        playing: playing,
                        size: _vinylSize(context),
                      ),
                    ),
                  ),
          ),
        ),
        _InfoSection(),
        const _ProgressSection(),
        const _ControlBar(),
        _BottomStrip(
          onToggleLyrics: onToggleLyrics,
          showLyrics: showLyrics,
        ),
      ],
    );
  }

  double _vinylSize(BuildContext context) {
    final double h = MediaQuery.sizeOf(context).height;
    final double w = MediaQuery.sizeOf(context).width;
    return (h * 0.42).clamp(200.0, w * 0.88);
  }
}

// ---------------------------------------------------------------- 平板

class _TabletBody extends ConsumerWidget {
  const _TabletBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));

    return Column(
      children: <Widget>[
        const _TopBar(),
        Expanded(
          child: Row(
            children: <Widget>[
              // 左：黑胶 + 信息 + 控制
              Expanded(
                flex: 5,
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: Center(
                        child: VinylDisc(
                          cover: track?.cover,
                          playing: playing,
                          size: 300,
                        ),
                      ),
                    ),
                    _InfoSection(),
                    const _ProgressSection(),
                    const _ControlBar(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              // 右：歌词
              Expanded(
                flex: 5,
                child: Container(
                  margin: const EdgeInsets.fromLTRB(8, 12, 8, 24),
                  child: const KaraokeLyricsView(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 顶部栏

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? title =
        ref.watch(playerProvider.select((PlayerState s) => s.queueTitle));

    return SizedBox(
      height: 52,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 8),
          IconButton(
            tooltip: '收起',
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
          ),
          Expanded(
            child: Text(
              title ?? 'MingMusic',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const _FavoriteButton(),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

class _FavoriteButton extends ConsumerWidget {
  const _FavoriteButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool fav = track == null
        ? false
        : ref.watch(favoriteTracksProvider
            .select((List<Track> l) => l.any((Track t) => t.id == track.id)));

    return IconButton(
      tooltip: fav ? '取消收藏' : '收藏',
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Icon(
          fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          key: ValueKey<bool>(fav),
          color: fav
              ? AppConstants.brandColor
              : Colors.white.withValues(alpha: 0.85),
          size: 24,
        ),
      ),
      onPressed: track == null
          ? null
          : () => ref.read(favoriteTracksProvider.notifier).toggle(track),
    );
  }
}

// ---------------------------------------------------------------- 信息区

class _InfoSection extends ConsumerWidget {
  const _InfoSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool vip = track?.isVipOnly ?? false;
    final TextTheme theme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  track?.title ?? '未在播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 21,
                  ),
                ),
              ),
              if (vip) ...<Widget>[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: AppConstants.brandColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'VIP',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            track?.artist ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.66),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 进度

class _ProgressSection extends StatelessWidget {
  const _ProgressSection();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: PlayerProgressBar(),
    );
  }
}

// ---------------------------------------------------------------- 控制栏

class _ControlBar extends ConsumerWidget {
  const _ControlBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    final bool busy = ref.watch(playerProvider.select((PlayerState s) =>
        s.processing == AppProcessingState.loading ||
        s.processing == AppProcessingState.buffering));

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          const _RepeatButton(),
          _CtrlIcon(
            icon: Icons.skip_previous_rounded,
            size: 36,
            onTap: () => ref.read(playerProvider.notifier).previous(),
          ),
          _CtrlIcon(
            icon: playing
                ? Icons.pause_circle_filled_rounded
                : Icons.play_circle_filled_rounded,
            size: 66,
            busy: busy,
            onTap: () => ref.read(playerProvider.notifier).playPause(),
          ),
          _CtrlIcon(
            icon: Icons.skip_next_rounded,
            size: 36,
            onTap: () => ref.read(playerProvider.notifier).next(),
          ),
          _CtrlIcon(
            icon: Icons.queue_music_rounded,
            size: 30,
            onTap: () => showQueueSheet(context),
          ),
        ],
      ),
    );
  }
}

class _CtrlIcon extends StatelessWidget {
  const _CtrlIcon({
    required this.icon,
    required this.size,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return SizedBox(
        width: size,
        height: size,
        child: Padding(
          padding: EdgeInsets.all(size * 0.28),
          child: const CircularProgressIndicator(
            strokeWidth: 2.4,
            color: Colors.white,
          ),
        ),
      );
    }
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: size, color: Colors.white),
    );
  }
}

class _RepeatButton extends ConsumerWidget {
  const _RepeatButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RepeatMode mode =
        ref.watch(playerProvider.select((PlayerState s) => s.repeat));

    final (IconData icon, Color color, String tip) = switch (mode) {
      RepeatMode.off => (
          Icons.loop_rounded,
          Colors.white.withValues(alpha: 0.85),
          '列表循环',
        ),
      RepeatMode.all => (
          Icons.repeat_rounded,
          AppConstants.brandColor,
          '顺序循环',
        ),
      RepeatMode.one => (
          Icons.repeat_one_rounded,
          AppConstants.brandColor,
          '单曲循环',
        ),
    };

    return IconButton(
      tooltip: tip,
      onPressed: () => ref.read(playerProvider.notifier).cycleRepeat(),
      icon: Icon(icon, size: 27, color: color),
    );
  }
}

// ---------------------------------------------------------------- 底部条

class _BottomStrip extends ConsumerWidget {
  const _BottomStrip({
    required this.onToggleLyrics,
    required this.showLyrics,
  });

  final VoidCallback onToggleLyrics;
  final bool showLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AudioQuality quality = ref.watch(audioQualityProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Row(
        children: <Widget>[
          Text(
            _qualityLabel(quality),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: showLyrics ? '黑胶视图' : '逐字歌词',
            onPressed: onToggleLyrics,
            icon: Icon(
              Icons.lyrics_rounded,
              size: 22,
              color: showLyrics
                  ? AppConstants.brandColor
                  : Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  String _qualityLabel(AudioQuality q) {
    return switch (q) {
      AudioQuality.standard => '标准音质',
      AudioQuality.higher => '较高音质',
      AudioQuality.exhigh => '极高音质',
      AudioQuality.lossless => '无损音质',
    };
  }
}
