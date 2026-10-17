/// 全屏播放页（仿 Zephyr-Music 播放界面，支持高度自定义）：
///
///  - 显示模式（NpDisplayMode）：自适应（平板双列 / 手机可切换）/ 仅封面 / 仅歌词；
///  - 歌词页交互：单击任意区域切换封面/歌词；双击歌词行 seek 到该行；
///    切换视图时直接显示当前播放行（固定直显，无滑动动画）；
///  - 顶栏：收起 / 歌手名（仿网易云）/ 评论入口 / 播放页自定义 / 喜欢；
///  - 信息区：标题+VIP / 歌手 / 评论数点赞行（仿网易云）；
///  - 进度行：当前时间 — 音质标签（居中，仿网易云）— 总时长；
///  - hidePlayerControls：隐藏控制栏（仅保留进度条）；
///  - 手势：下滑收起播放页；左右滑动切歌（避开边缘 20px，避坑指南 4）。
library;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../auth/providers/auth_providers.dart';
import '../../comments/presentation/comments_page.dart';
import '../../comments/providers/comments_providers.dart'
    show songCommentCountProvider;
import '../../library/domain/track.dart';
import '../../library/providers/library_providers.dart';
import '../../settings/domain/settings_models.dart' show AudioQuality;
import '../../settings/providers/settings_providers.dart'
    show audioQualityProvider;
import '../domain/np_settings.dart';
import '../providers/np_settings_providers.dart';
import '../providers/player_providers.dart';
import 'np_settings_sheet.dart';
import 'widgets/cover_art_view.dart';
import 'widgets/karaoke_lyrics_view.dart';
import 'widgets/player_background.dart';
import 'widgets/progress_bar.dart';
import 'widgets/queue_sheet.dart';

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
  /// 手机端封面/歌词切换：null = 跟随显示模式（both 默认封面）
  bool? _paneOverride;
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
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
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

    final bool switchable;
    final bool showLyrics;
    switch (cfg.displayMode) {
      case NpDisplayMode.both:
        // 手机：单列可切换（默认封面）；平板：双列
        switchable = !isWide;
        showLyrics = _paneOverride ?? false;
      case NpDisplayMode.cover:
        switchable = false;
        showLyrics = false;
      case NpDisplayMode.lyrics:
        switchable = false;
        showLyrics = true;
    }

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
                  ? _TabletBody(mode: cfg.displayMode)
                  : _PhoneBody(
                      showLyrics: showLyrics,
                      switchable: switchable,
                      onToggleLyrics: switchable
                          ? () => setState(() {
                                _paneOverride = !showLyrics;
                              })
                          : null,
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
    required this.switchable,
    required this.onToggleLyrics,
  });

  final bool showLyrics;
  final bool switchable;
  final VoidCallback? onToggleLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));

    return Column(
      children: <Widget>[
        const _TopBar(),
        // 上半区：封面 ⇄ 歌词
        Expanded(
          child: AnimatedSwitcher(
            duration: AppConstants.playerPageFlip,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> anim) =>
                FadeTransition(opacity: anim, child: child),
            child: showLyrics
                ? SizedBox(
                    key: const ValueKey<String>('lyrics'),
                    width: double.infinity,
                    // 单击歌词区域切换视图；直显当前播放行（固定行为）
                    child: KaraokeLyricsView(
                      key: const ValueKey<String>('lyrics-view'),
                      onToggleView: onToggleLyrics,
                      lineExtent: _lyricExtent(cfg),
                    ),
                  )
                : SizedBox(
                    key: const ValueKey<String>('cover'),
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: onToggleLyrics,
                      child: Center(
                        child: CoverArtView(
                          style: cfg.coverStyle,
                          cover: track?.cover,
                          playing: playing,
                          size: _coverSize(context),
                          scale: cfg.coverScale,
                          shadow: cfg.coverShadow,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        if (!cfg.hidePlayerControls) ...<Widget>[
          _InfoSection(),
          const _ProgressSection(),
          const _ControlBar(),
          _BottomStrip(
            onToggleLyrics: onToggleLyrics,
            showLyrics: showLyrics,
          ),
        ] else
          const _ProgressSection(),
      ],
    );
  }

  double _coverSize(BuildContext context) {
    final double h = MediaQuery.sizeOf(context).height;
    final double w = MediaQuery.sizeOf(context).width;
    return (h * (showLyrics ? 0.36 : 0.42)).clamp(200.0, w * 0.88);
  }

  double _lyricExtent(NpPlayerSettings cfg) {
    // 行高随字号/行距微调：基础 58 + 超出默认部分的补偿
    return (AppConstants.yrcLineExtent +
            (cfg.lyricFontSize - 17) * 0.9 +
            (cfg.lyricLineGap - 14) * 0.45)
        .clamp(44.0, 96.0);
  }
}

// ---------------------------------------------------------------- 平板

class _TabletBody extends ConsumerWidget {
  const _TabletBody({required this.mode});

  final NpDisplayMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));

    final Widget coverColumn = Column(
      children: <Widget>[
        Expanded(
          child: Center(
            child: CoverArtView(
              style: cfg.coverStyle,
              cover: track?.cover,
              playing: playing,
              size: 300,
              scale: cfg.coverScale,
              shadow: cfg.coverShadow,
            ),
          ),
        ),
        _InfoSection(),
        const _ProgressSection(),
        if (!cfg.hidePlayerControls) ...<Widget>[
          const _ControlBar(),
          const SizedBox(height: 12),
        ],
      ],
    );

    switch (mode) {
      case NpDisplayMode.both:
        return Column(
          children: <Widget>[
            const _TopBar(),
            Expanded(
              child: Row(
                children: <Widget>[
                  Expanded(flex: 5, child: coverColumn),
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
      case NpDisplayMode.lyrics:
        return Column(
          children: <Widget>[
            const _TopBar(),
            Expanded(
              child: const KaraokeLyricsView(),
            ),
          ],
        );
      case NpDisplayMode.cover:
        return Column(
          children: <Widget>[
            const _TopBar(),
            Expanded(child: coverColumn),
          ],
        );
    }
  }
}

// ---------------------------------------------------------------- 顶部栏

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? title =
        ref.watch(playerProvider.select((PlayerState s) => s.queueTitle));
    // 仿网易云：顶栏居中显示歌手名，无曲目时回退队列名
    final String center = (track?.artist.isNotEmpty ?? false)
        ? track!.artist
        : (title ?? 'MingMusic');

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
              center,
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
          const _CommentButton(),
          IconButton(
            tooltip: '播放页自定义',
            icon: Icon(
              Icons.tune_rounded,
              size: 22,
              color: Colors.white.withValues(alpha: 0.85),
            ),
            onPressed: () => showNpSettingsSheet(context),
          ),
          const _FavoriteButton(),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 评论入口

class _CommentButton extends ConsumerWidget {
  const _CommentButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    return IconButton(
      tooltip: '评论',
      icon: Icon(
        Icons.mode_comment_outlined,
        size: 21,
        color: Colors.white.withValues(alpha: 0.85),
      ),
      onPressed: track == null ? null : () => showCommentsPage(context, track),
    );
  }
}

// ---------------------------------------------------------------- 喜欢

class _FavoriteButton extends ConsumerWidget {
  const _FavoriteButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final AuthState auth = ref.watch(authProvider);

    if (track == null) {
      return IconButton(
        onPressed: null,
        icon: Icon(Icons.favorite_border_rounded,
            color: Colors.white.withValues(alpha: 0.4), size: 24),
      );
    }

    if (auth.loggedIn && track.neteaseId != null) {
      // 网易云喜欢
      final bool fav = auth.likedIds.contains(track.neteaseId);
      return IconButton(
        tooltip: fav ? '取消喜欢' : '喜欢',
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
        onPressed: () async {
          final String? error = await ref
              .read(authProvider.notifier)
              .toggleLikeSong(track.neteaseId!);
          if (error != null && context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(error)));
          }
        },
      );
    }

    // 本地收藏（游客）
    final bool fav = ref.watch(favoriteTracksProvider
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
      onPressed: () => ref.read(favoriteTracksProvider.notifier).toggle(track),
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
          if (track?.neteaseId != null) ...<Widget>[
            const SizedBox(height: 6),
            const _CountsRow(),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 点赞/评论计数行

/// 仿网易云：标题下方右侧 喜欢 + 评论数（点击评论跳转评论页）
class _CountsRow extends ConsumerWidget {
  const _CountsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    if (track == null) return const SizedBox.shrink();
    final int? songId = track.neteaseId;
    final int count = songId == null
        ? 0
        : ref.watch(songCommentCountProvider(songId)).value ?? 0;
    final Color tint = Colors.white.withValues(alpha: 0.78);

    return Row(
      children: <Widget>[
        const Spacer(),
        Icon(Icons.favorite_border_rounded, size: 20, color: tint),
        const SizedBox(width: 18),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showCommentsPage(context, track),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              children: <Widget>[
                Icon(Icons.mode_comment_outlined, size: 20, color: tint),
                if (count > 0) ...<Widget>[
                  const SizedBox(width: 4),
                  Text(
                    _formatWan(count),
                    style: TextStyle(fontSize: 11.5, color: tint),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 仿网易云计数：千以内原样，万以上「x万+」（999+w+ 风格）
  static String _formatWan(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(0)}亿+';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(0)}万+';
    return '$n';
  }
}

// ---------------------------------------------------------------- 进度

class _ProgressSection extends ConsumerWidget {
  const _ProgressSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AudioQuality quality = ref.watch(audioQualityProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: PlayerProgressBar(
        // 仿网易云：进度行中央显示音质标签
        centerLabel: Text(
          switch (quality) {
            AudioQuality.standard => '标准音质',
            AudioQuality.higher => '较高音质',
            AudioQuality.exhigh => '极高音质',
            AudioQuality.lossless => '无损音质',
          },
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 11.5,
          ),
        ),
      ),
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

  final VoidCallback? onToggleLyrics;
  final bool showLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Row(
        children: <Widget>[
          const Spacer(),
          if (onToggleLyrics != null)
            IconButton(
              tooltip: showLyrics ? '封面视图' : '逐字歌词',
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
}
