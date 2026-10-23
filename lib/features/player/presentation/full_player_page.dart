/// 全屏播放页（仿网易云/Zephyr-Music，支持高度自定义）：
///
///  - 显示模式（NpDisplayMode）：自适应（平板双列 / 手机可切换）/ 仅封面 / 仅歌词；
///  - 封面区（需求）：单击封面 → 切换歌词视图；左右滑动**不显示相邻封面**，
///    拖动时显示「刷新布局」（环形箭头 + 松手提示），松手超过阈值切歌，
///    切换中显示加载圈；长按封面全屏查看 + 保存；
///  - 封面 Hero 与 Mini 播放条同 tag —— 路由转场时无缝放大，配合背景模糊渐入；
///  - 方形封面：播放时保持尺寸，暂停时明显缩小；
///  - 信息区（需求）：歌名/歌手下移；喜欢 + 评论键与歌名/歌手同一水平线；
///    歌名过长平滑跑马灯（尽头停留 3s 重新滚动）；MV 徽标仅文本可开关；
///  - 歌词页：单击切换封面/歌词；双击歌词行 seek；左右滑切歌；
///  - 播放键：双环描边样式（无白色填充底）；
///  - 红心：喜欢切换 + 可选迸发动效；切歌时节流刷新喜欢列表（保障点亮）；
///  - 底部功能条：按「播放页底部功能自定义」勾选渲染，长按气泡提示，
///    底部间距上移（需求：太靠近底部显得奇怪）；
///  - 手势：下滑收起播放页。
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;
import 'dart:ui' as ui show lerpDouble;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/lyrics.dart' show activeLyricIndex;
import '../../../core/utils/yrc_lyrics.dart' show activeYrcIndex;
import '../../../core/widgets/cover_image.dart'
    show CoverImage, CoverSize, fetchBytes;
import '../../../core/widgets/marquee_text.dart';
import '../../auth/providers/auth_providers.dart';
import '../../comments/providers/comments_providers.dart'
    show songCommentCountProvider;
import '../../library/data/download_service.dart';
import '../../library/domain/track.dart';
import '../../settings/domain/settings_models.dart'
    show AudioQuality;
import '../../settings/providers/settings_providers.dart'
    show audioQualityProvider;
import '../domain/np_settings.dart';
import '../providers/lyrics_providers.dart'
    show ParsedLyrics, currentLyricsProvider;
import '../providers/np_settings_providers.dart';
import '../providers/player_providers.dart';
import 'player_more_sheet.dart';
import 'widgets/cover_art_view.dart';
import 'widgets/cover_viewer.dart';
import 'widgets/karaoke_lyrics_view.dart';
import 'widgets/media_output_sheet.dart';
import 'widgets/player_background.dart';
import 'widgets/progress_bar.dart';
import 'widgets/quality_sheet.dart';
import 'widgets/queue_sheet.dart';
import 'widgets/similar_songs_sheet.dart';

class FullPlayerPage extends ConsumerStatefulWidget {
  const FullPlayerPage({super.key});

  @override
  ConsumerState<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends ConsumerState<FullPlayerPage> {
  /// 手机端封面/歌词切换：null = 跟随显示模式（both 默认封面）
  bool? _paneOverride;

  // ---------------------------------------------------------------- gestures

  void _onHorizontalDragEnd(DragEndDetails details) {
    final double vx = details.velocity.pixelsPerSecond.dx;
    // 歌词区域左右滑切歌（封面区域由 PageView 自己处理）
    if (vx < -AppConstants.dismissVelocityThreshold * 0.7) {
      ref.read(playerProvider.notifier).next();
    } else if (vx > AppConstants.dismissVelocityThreshold * 0.7) {
      ref.read(playerProvider.notifier).previous();
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    _dragDy += details.delta.dy > 0 ? details.delta.dy : 0;
  }

  double _dragDy = 0;

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
        onHorizontalDragEnd: _onHorizontalDragEnd,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 背景模糊随页面入场动画渐进（需求：Hero + 背景模糊动画）
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 480),
              curve: Curves.easeOutCubic,
              builder: (BuildContext ctx, double t, Widget? child) =>
                  PlayerBackground(blurFactor: t, dimFactor: t),
            ),
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

class _PhoneBody extends ConsumerStatefulWidget {
  const _PhoneBody({
    required this.showLyrics,
    required this.switchable,
    required this.onToggleLyrics,
  });

  final bool showLyrics;
  final bool switchable;
  final VoidCallback? onToggleLyrics;

  @override
  ConsumerState<_PhoneBody> createState() => _PhoneBodyState();
}

class _PhoneBodyState extends ConsumerState<_PhoneBody> {
  double _coverSize(BuildContext context) {
    final double h = MediaQuery.sizeOf(context).height;
    final double w = MediaQuery.sizeOf(context).width;
    return (h * (widget.showLyrics ? 0.36 : 0.42)).clamp(200.0, w * 0.88);
  }

  @override
  Widget build(BuildContext context) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);

    // 需求「歌曲名称整块区域应透明可见歌词」：
    //  歌词视图铺满整个可视区，歌名/进度/控制区以透明浮层压在其上，
    //  歌词滚动时从歌名区域背后穿过；封面模式保持原有上下排布，
    //  仅把封面区向上避让浮层高度。
    final Widget bottomOverlay = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _InfoSection(),
        const _ProgressSection(),
        const _ControlBar(),
        const _BottomStrip(),
      ],
    );

    return Column(
      children: <Widget>[
        const _TopBar(),
        Expanded(
          child: _PlayerStackLayout(
            showLyrics: widget.showLyrics,
            cfg: cfg,
            coverSize: _coverSize(context),
            onToggleLyrics: widget.onToggleLyrics,
            bottomOverlay: bottomOverlay,
          ),
        ),
      ],
    );
  }
}

/// 手机端主布局：歌词/封面铺满 + 底部透明浮层（信息区/进度/控制/功能条）。
/// 浮层高度实时测量后回填给歌词（滚动居中避让）与封面（向上避让）。
class _PlayerStackLayout extends ConsumerStatefulWidget {
  const _PlayerStackLayout({
    required this.showLyrics,
    required this.cfg,
    required this.coverSize,
    required this.onToggleLyrics,
    required this.bottomOverlay,
  });

  final bool showLyrics;
  final NpPlayerSettings cfg;
  final double coverSize;
  final VoidCallback? onToggleLyrics;
  final Widget bottomOverlay;

  @override
  ConsumerState<_PlayerStackLayout> createState() => _PlayerStackLayoutState();
}

class _PlayerStackLayoutState extends ConsumerState<_PlayerStackLayout> {
  /// 底部浮层实测高度（初值给常见机型的估算值，首帧后校正）
  double _overlayHeight = 252;

  final GlobalKey _overlayKey = GlobalKey();

  void _measureOverlay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? ctx = _overlayKey.currentContext;
      final double? h = ctx?.size?.height;
      if (h != null && h > 0 && (h - _overlayHeight).abs() > 0.5) {
        setState(() => _overlayHeight = h);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _measureOverlay();

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 中层：封面 ⇄ 歌词（AnimatedSwitcher 平滑切换）
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: AppConstants.playerPageFlip,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> anim) =>
                FadeTransition(opacity: anim, child: child),
            child: widget.showLyrics
                ? Padding(
                    key: const ValueKey<String>('lyrics'),
                    // 需求：歌词不再全透明穿行 —— 只在歌曲名称上方、
                    // 底部信息栏下沿之上的区域显示（与封面分支同构的
                    // 底部避让，歌词不再延伸到信息区背后）
                    padding: EdgeInsets.only(bottom: _overlayHeight),
                    child: KaraokeLyricsView(
                      key: const ValueKey<String>('lyrics-view'),
                      onToggleView: widget.onToggleLyrics,
                      bottomInset: 0,
                    ),
                  )
                : Padding(
                    key: const ValueKey<String>('cover'),
                    // 封面模式：向上避让浮层，封面仍在剩余空间内居中
                    padding: EdgeInsets.only(bottom: _overlayHeight),
                    child: LayoutBuilder(
                      builder: (BuildContext ctx, BoxConstraints cons) {
                        // 封面页歌词预览占位预留，避免溢出
                        final double reserve = switch (widget.cfg.coverLyrics) {
                          NpCoverLyricsMode.none => 0.0,
                          NpCoverLyricsMode.one => 52.0,
                          NpCoverLyricsMode.two => 82.0,
                        };
                        final double maxCover =
                            (cons.maxHeight - reserve).clamp(0.0, cons.maxHeight);
                        final double size =
                            widget.coverSize.clamp(0.0, maxCover).toDouble();
                        return _CoverSwipeArea(
                          cfg: widget.cfg,
                          size: size,
                          onToggleLyrics: widget.onToggleLyrics,
                        );
                      },
                    ),
                  ),
          ),
        ),
        // 顶层：透明底部浮层（歌词从其背后穿过）
        Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            key: _overlayKey,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[widget.bottomOverlay],
          ),
        ),
      ],
    );
  }
}

/// 封面手势区（需求重构：滑动切歌无感化）：
///  - 封面 1:1 跟手平滑移动（不再视差缩水），无「松手切换」提示浮层、
///    无刷新图标、无「正在切换」遮罩 —— 整个过程不露出背景与歌词；
///  - 松手超过阈值：旧封面沿拖动方向平滑滑出屏幕，同时新封面从反方向
///    平滑滑入（相邻封面取自播放队列并预取，画面全程无空档）；
///  - 未过阈值：封面平滑回弹；
///  - 单击封面 → 切换歌词视图；长按封面 → 全屏查看 + 保存。
class _CoverSwipeArea extends ConsumerStatefulWidget {
  const _CoverSwipeArea({
    required this.cfg,
    required this.size,
    required this.onToggleLyrics,
  });

  final NpPlayerSettings cfg;
  final double size;
  final VoidCallback? onToggleLyrics;

  @override
  ConsumerState<_CoverSwipeArea> createState() => _CoverSwipeAreaState();
}

class _CoverSwipeAreaState extends ConsumerState<_CoverSwipeArea>
    with SingleTickerProviderStateMixin {
  /// 触发切歌的拖动阈值
  static const double _triggerDistance = 88;

  /// 滑出/滑入共用动画（切歌过程 = 旧封面滑出 + 新封面滑入同时进行）
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: 1,
  )..addStatusListener((AnimationStatus st) {
      if (st == AnimationStatus.completed) _onSlideDone();
    });

  double _dragDx = 0;

  /// 切歌方向：1 = 右滑（上一首，旧封面从右侧出）；-1 = 左滑（下一首）
  int _dir = 1;

  /// 滑出阶段的旧封面 / 滑入阶段的新封面（null = 非过渡态）
  String? _outgoingCover;
  String? _incomingCover;

  /// 松手时的拖动偏移（滑出动画起点）
  double _releaseDx = 0;

  bool get _transitioning => _outgoingCover != null;

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 手势

  void _onDragUpdate(DragUpdateDetails d) {
    if (_transitioning) return; // 过渡中忽略新拖动，避免抖动
    setState(() => _dragDx += d.delta.dx);
    // 拖动开始即预取相邻封面（内存缓存），保证滑入画面无空档
    _prefetchNeighbors();
  }

  Future<void> _onDragEnd(DragEndDetails d) async {
    if (_transitioning) return;
    final double dx = _dragDx;
    if (dx.abs() < _triggerDistance) {
      // 未过阈值：平滑回弹
      _startSpringBack(dx);
      return;
    }
    _startSwitch(dx);
  }

  /// 平滑回弹（未过阈值）
  void _startSpringBack(double from) {
    setState(() {
      _outgoingCover = ref.read(playerProvider).currentTrack?.cover;
      _incomingCover = null;
      _releaseDx = from;
      _dir = 1;
    });
    _slide.forward(from: 0);
  }

  /// 切歌过渡：旧封面沿拖动方向滑出，新封面从反方向滑入；同时立即切歌
  void _startSwitch(double dx) {
    final PlayerState ps = ref.read(playerProvider);
    if (!ps.hasQueue) return;
    final int len = ps.queue.length;
    final bool backward = dx > 0; // 右滑 → 上一首
    _dir = backward ? 1 : -1;
    final int neighborIndex = backward
        ? (ps.index - 1 + len) % len
        : (ps.index + 1) % len;
    final String? outCover = ps.currentTrack?.cover;
    final String? inCover = ps.queue[neighborIndex].cover;
    setState(() {
      _outgoingCover = outCover;
      _incomingCover = inCover;
      _releaseDx = dx;
      _dragDx = 0;
    });
    _slide.forward(from: 0);
    // 音频切歌与动画并行：内核队列已预解析直链，seek 即播
    final PlayerNotifier notifier = ref.read(playerProvider.notifier);
    if (backward) {
      unawaited(notifier.previous());
    } else {
      unawaited(notifier.next());
    }
  }

  void _onSlideDone() {
    if (!mounted || !_transitioning) return;
    setState(() {
      _outgoingCover = null;
      _incomingCover = null;
      _releaseDx = 0;
    });
  }

  // ---------------------------------------------------------------- 预取

  /// 预取相邻封面（播放页大图档位），命中内存缓存后滑入无空档
  void _prefetchNeighbors() {
    final PlayerState ps = ref.read(playerProvider);
    if (!ps.hasQueue || ps.queue.length <= 1) return;
    final int len = ps.queue.length;
    for (final int idx in <int>[
      (ps.index + 1) % len,
      (ps.index - 1 + len) % len,
    ]) {
      final String? c = ps.queue[idx].cover;
      if (c != null && c.startsWith('http')) {
        unawaited(fetchBytes(c, CoverSize.large));
      }
    }
  }

  // ---------------------------------------------------------------- 渲染

  @override
  Widget build(BuildContext context) {
    final PlayerState ps = ref.watch(playerProvider);
    final Track? track = ps.currentTrack;
    final double p = (_dragDx.abs() / _triggerDistance).clamp(0.0, 1.0);

    // 需求：封面页歌词预览（借鉴 kgka_Music_hl）—— 封面下方显示当前行，
    // 可选一行/两行，默认一行；占位高度在封面尺寸计算时预留，避免溢出。
    final bool showPreview = widget.cfg.coverLyrics != NpCoverLyricsMode.none;

    final double side = widget.size + 48; // 完全滑出屏幕所需距离

    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggleLyrics,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: widget.size,
              height: widget.size,
              child: AnimatedBuilder(
                animation: _slide,
                builder: (BuildContext ctx, Widget? _) {
                  final double t = _slide.value.clamp(0.0, 1.0);

                  // ---- 过渡态：切歌（旧滑出+新滑入）/ 回弹（旧封面回中心）
                  if (_outgoingCover != null) {
                    final bool isSwitch = _incomingCover != null;
                    // 切歌：旧封面滑出屏幕 + 新封面从反方向滑入；
                    // 回弹：旧封面从松手位置平滑回到中心
                    final double outEnd = isSwitch ? _dir * side : 0.0;
                    final double outX = ui.lerpDouble(
                        _releaseDx, outEnd, Curves.easeOutCubic.transform(t))!;

                    return Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        Transform.translate(
                          offset: Offset(outX, 0),
                          child: _FrozenCover(
                            cover: _outgoingCover,
                            size: widget.size,
                            style: widget.cfg.coverStyle,
                          ),
                        ),
                        if (isSwitch)
                          Transform.translate(
                            offset: Offset(
                                ui.lerpDouble(
                                    -_dir * side, 0.0,
                                    Curves.easeOutCubic.transform(t))!,
                                0),
                            child: _FrozenCover(
                              cover: _incomingCover,
                              size: widget.size,
                              style: widget.cfg.coverStyle,
                            ),
                          ),
                      ],
                    );
                  }

                  // ---- 常规态：封面 1:1 跟手（平滑移动）+ 轻微缩放反馈
                  return Transform.translate(
                    offset: Offset(_dragDx, 0),
                    child: Transform.scale(
                      scale: 1 - 0.04 * p,
                      child: CoverArtView(
                        style: widget.cfg.coverStyle,
                        cover: track?.cover,
                        playing: ps.playing,
                        size: widget.size,
                        scale: widget.cfg.coverScale,
                        shadow: widget.cfg.coverShadow,
                        squareRadius: widget.cfg.squareCoverRadius,
                        onLongPress: track?.cover == null
                            ? null
                            : () => showCoverViewer(
                                  context,
                                  cover: track!.cover,
                                  title: '${track.title} - ${track.artist}',
                                ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // 需求：封面页歌词预览（kgka 风格：当前行大字 + 副行，可选一行/两行）
            if (showPreview) ...<Widget>[
              const SizedBox(height: 12),
              _CoverLyricsPreview(
                mode: widget.cfg.coverLyrics,
                width: widget.size,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 过渡态的静态封面（不做 Hero/暂停缩放/长按，纯画面）：
/// 与 CoverArtView 相同的投影观感，图像走 CoverImage 内存缓存即时渲染。
class _FrozenCover extends StatelessWidget {
  const _FrozenCover({
    required this.cover,
    required this.size,
    required this.style,
  });

  final String? cover;
  final double size;
  final NpCoverStyle style;

  @override
  Widget build(BuildContext context) {
    final double radius = switch (style) {
      NpCoverStyle.square => 0,
      NpCoverStyle.circle => size / 2,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CoverImage(src: cover, size: size, radius: 0, coverSize: CoverSize.large),
      ),
    );
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
              squareRadius: cfg.squareCoverRadius,
              onLongPress: track?.cover == null
                  ? null
                  : () => showCoverViewer(
                        context,
                        cover: track!.cover,
                        title: '${track.title} - ${track.artist}',
                      ),
            ),
          ),
        ),
        _InfoSection(),
        const _ProgressSection(),
        const _ControlBar(),
        const SizedBox(height: 8),
        const _BottomStrip(),
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

/// 仿网易云顶栏：仅 收起 + 居中歌手名
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
          // 右侧占位：与左侧收起键等宽，保证歌手名绝对居中
          const SizedBox(width: 56),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 信息区

/// 信息区（需求重排）：
///  - 歌曲名称和歌手名向下移动（padding 加大）；
///  - 喜欢 + 评论按键与歌曲名称/歌手名称位于同一水平线（右侧）；
///  - 歌名过长平滑跑马灯（尽头停留 3s 重新滚动）；
///  - MV 徽标仅显示 MV 文本（无播放键）、适当缩小、可在设置开关（默认开启）；
///  - 喜欢/评论键 hover/按压反馈；切歌时节流刷新喜欢列表保障红心点亮。
class _InfoSection extends ConsumerStatefulWidget {
  const _InfoSection();

  @override
  ConsumerState<_InfoSection> createState() => _InfoSectionState();
}

class _InfoSectionState extends ConsumerState<_InfoSection> {
  /// 红心迸发动效触发器
  bool _burst = false;

  int _lastSongId = 0;
  DateTime _lastLikeRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureLikeFresh();
  }

  /// 需求：播放喜欢歌曲时红心需点亮 —— 切歌时节流刷新喜欢列表，
  /// 防止「喜欢列表尚未加载/加载失败导致红心未点亮」。
  void _ensureLikeFresh() {
    final Track? track = ref.read(playerProvider).currentTrack;
    final int? songId = track?.neteaseId;
    if (songId == null || songId <= 0) return;
    if (songId == _lastSongId) return;
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return;
    _lastSongId = songId;
    final DateTime now = DateTime.now();
    if (now.difference(_lastLikeRefresh).inSeconds < 15) return;
    _lastLikeRefresh = now;
    ref.read(authProvider.notifier).refreshLikeList();
  }

  Future<void> _toggleLike(Track track) async {
    final int songId = track.neteaseId ?? 0;
    if (songId <= 0) return;
    final NpPlayerSettings cfg = ref.read(npSettingsProvider);
    final bool liked = ref.read(authProvider).likedIds.contains(songId);
    final String? error =
        await ref.read(authProvider.notifier).toggleLikeSong(songId);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    if (cfg.heartEffect && !liked) {
      setState(() => _burst = true);
      Future<void>.delayed(const Duration(milliseconds: 620), () {
        if (mounted) setState(() => _burst = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool vip = track?.isVipOnly ?? false;
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final TextTheme theme = Theme.of(context).textTheme;
    final Color tint = Colors.white.withValues(alpha: 0.78);
    final int? songId = track?.neteaseId;
    final int commentCount = songId == null || songId <= 0
        ? 0
        : ref.watch(songCommentCountProvider(songId)).value ?? 0;
    final bool liked = (songId ?? 0) > 0 &&
        ref.watch(authProvider
            .select((AuthState s) => s.likedIds.contains(songId)));

    return Padding(
      // 需求：歌曲名称和歌手名称往下移动一点
      padding: const EdgeInsets.fromLTRB(24, 22, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 歌名（跑马灯）+ VIP 标识
                // 需求：VIP 徽标应紧靠歌名右侧，而非紧贴红心左侧 ——
                // Flexible 让跑马灯收缩到文本实际宽度，短歌名时 VIP
                // 直接跟在文字后面；长歌名跑马灯滚动，VIP 靠右定位。
                Row(
                  children: <Widget>[
                    Flexible(
                      child: MarqueeText(
                        track?.title ?? '未在播放',
                        style: theme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 21,
                        ),
                      ),
                    ),
                    if (vip) ...<Widget>[
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1.5),
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
                const SizedBox(height: 5),
                // 歌手 + MV 胶囊（需求：仅 MV 文本、缩小、可开关）
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        track?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.66),
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (cfg.showMvBadge && (track?.mvId ?? 0) > 0) ...<Widget>[
                      const SizedBox(width: 8),
                      _MvPill(mvId: track!.mvId!, title: track.title),
                    ],
                    const SizedBox(width: 4),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 喜欢（服务器红心，乐观更新；hover/按压反馈）
          _PlayerIconButton(
            tooltip: liked ? '取消喜欢' : '喜欢',
            onTap: track == null ? null : () => _toggleLike(track),
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 22,
                  color: liked ? AppConstants.brandColor : tint,
                ),
                if (_burst)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _HeartBurst(color: AppConstants.brandColor),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 评论（hover/按压反馈）
          // 需求：评论数字改为覆盖在评论图标上方（角标），不再显示在右侧
          _PlayerIconButton(
            tooltip: '评论',
            onTap: track == null
                ? null
                : () => context.push('/comments', extra: track),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: <Widget>[
                Icon(Icons.mode_comment_outlined, size: 21, color: tint),
                if (commentCount > 0)
                  Positioned(
                    top: -5,
                    right: -10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 3.5, vertical: 0.5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.30),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        _formatWan(commentCount),
                        style: const TextStyle(
                          fontSize: 9.5,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 仿网易云计数：千以内原样，万以上「x万+」
  static String _formatWan(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(0)}亿+';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(0)}万+';
    return '$n';
  }
}

/// 播放页圆形交互键：hover 放大 + 半透明底、按压缩小（需求：喜欢/评论有 hover 反馈）
class _PlayerIconButton extends StatefulWidget {
  const _PlayerIconButton({
    required this.onTap,
    required this.child,
    this.tooltip,
  });

  final VoidCallback? onTap;
  final Widget child;
  final String? tooltip;

  @override
  State<_PlayerIconButton> createState() => _PlayerIconButtonState();
}

class _PlayerIconButtonState extends State<_PlayerIconButton> {
  bool _hover = false;
  bool _press = false;

  @override
  Widget build(BuildContext context) {
    final Widget icon = AnimatedScale(
      scale: _press ? 0.84 : (_hover ? 1.1 : 1.0),
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _hover
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.transparent,
        ),
        child: widget.child,
      ),
    );

    Widget result = GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _press = true),
      onTapUp: (_) => setState(() => _press = false),
      onTapCancel: () => setState(() => _press = false),
      child: MouseRegion(
        cursor: widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _press = false;
        }),
        child: icon,
      ),
    );

    if (widget.tooltip != null) {
      result = Tooltip(
        message: widget.tooltip!,
        preferBelow: false,
        verticalOffset: 24,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(fontSize: 11.5, color: Colors.white),
        child: result,
      );
    }
    return result;
  }
}

/// 红心迸发：一个放大的心形从实心向外扩散淡出
class _HeartBurst extends StatefulWidget {
  const _HeartBurst({required this.color});

  final Color color;

  @override
  State<_HeartBurst> createState() => _HeartBurstState();
}

class _HeartBurstState extends State<_HeartBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (BuildContext ctx, Widget? _) {
        final double t = Curves.easeOutCubic.transform(_ctrl.value);
        return CustomPaint(
          painter: _HeartBurstPainter(
            color: widget.color,
            progress: t,
          ),
        );
      },
    );
  }
}

class _HeartBurstPainter extends CustomPainter {
  const _HeartBurstPainter({required this.color, required this.progress});

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    // 外圈扩散环
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4 * (1 - progress)
      ..color = color.withValues(alpha: (1 - progress) * 0.9);
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.shortestSide * (0.5 + progress * 0.9),
      ring,
    );

    // 中心放大的心
    final Paint heart = Paint()
      ..color = color.withValues(alpha: (1 - progress) * 0.65)
      ..style = PaintingStyle.fill;
    final double s = size.shortestSide * (0.28 + progress * 0.34);
    final Path p = Path()
      ..moveTo(size.width / 2, size.height / 2 + s * 0.32)
      ..cubicTo(
        size.width / 2 - s * 1.1, size.height / 2 - s * 0.45,
        size.width / 2 - s * 0.34, size.height / 2 - s * 1.05,
        size.width / 2, size.height / 2 - s * 0.42,
      )
      ..cubicTo(
        size.width / 2 + s * 0.34, size.height / 2 - s * 1.05,
        size.width / 2 + s * 1.1, size.height / 2 - s * 0.45,
        size.width / 2, size.height / 2 + s * 0.32,
      );
    canvas.drawPath(p, heart);
  }

  @override
  bool shouldRepaint(_HeartBurstPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// ---------------------------------------------------------------- MV 入口

/// MV 胶囊（需求：只显示 MV 不显示播放键，适当缩小；设置可开关，默认开启）
/// 歌曲详情 mv 字段非零时展示，闭环：/mv/url + /mv/detail 播放页
class _MvPill extends StatelessWidget {
  const _MvPill({required this.mvId, required this.title});

  final int mvId;
  final String title;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push(
          '/mv/$mvId?title=${Uri.encodeComponent(title)}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.4), width: 1),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          'MV',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 9.5,
            height: 1.2,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 封面页歌词预览

/// 封面页歌词预览（需求：借鉴 kgka_Music_hl 封面页）：
///  - 当前播放行大字白色（跑马灯防溢出），副行淡色；
///  - 副行优先翻译（跟随「显示翻译副行」开关），无翻译显示下一行；
///  - 一行/两行两种模式，默认一行；无歌词时显示占位避免布局跳动；
///  - 换行时 AnimatedSwitcher 平滑过渡（对齐 kgka 260ms）。
class _CoverLyricsPreview extends ConsumerWidget {
  const _CoverLyricsPreview({required this.mode, required this.width});

  final NpCoverLyricsMode mode;
  final double width;

  ({String main, String sub}) _resolve(ParsedLyrics lyrics, Duration position,
      bool preferTranslation) {
    if (lyrics.hasYrc) {
      final int idx = activeYrcIndex(lyrics.yrcLines, position);
      if (idx < 0) return (main: '', sub: '');
      final cur = lyrics.yrcLines[idx];
      final String main = cur.text;
      String sub = '';
      if (!cur.isMetadata) {
        final String t = lyrics.subLineFor(cur.start.inMilliseconds);
        if (preferTranslation && t.isNotEmpty) {
          sub = t;
        } else if (idx + 1 < lyrics.yrcLines.length) {
          sub = lyrics.yrcLines[idx + 1].text;
        }
      }
      return (main: main, sub: sub);
    }
    final int idx = activeLyricIndex(lyrics.lrcLines, position);
    if (idx < 0) return (main: '', sub: '');
    final String main = lyrics.lrcLines[idx].text;
    String sub = '';
    final String t =
        lyrics.subLineFor(lyrics.lrcLines[idx].time.inMilliseconds);
    if (preferTranslation && t.isNotEmpty) {
      sub = t;
    } else if (idx + 1 < lyrics.lrcLines.length) {
      sub = lyrics.lrcLines[idx + 1].text;
    }
    return (main: main, sub: sub);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ParsedLyrics lyrics = ref.watch(currentLyricsProvider);
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final Duration position =
        ref.watch(positionProvider).value ?? Duration.zero;

    final bool two = mode == NpCoverLyricsMode.two;
    final double height = two ? 62 : 34;

    if (lyrics.isEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Text(
            '暂无歌词',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final ({String main, String sub}) line =
        _resolve(lyrics, position, cfg.showTranslation);
    final String main = line.main.isEmpty ? '···' : line.main;
    final String sub = two ? line.sub : '';

    return SizedBox(
      width: width,
      height: height,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        child: Column(
          key: ValueKey<String>('$main|$sub'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            MarqueeText(
              main,
              textAlign: TextAlign.center,
              velocity: 32,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.94),
                fontSize: 16.5,
                height: 1.25,
                // kgka 观感：非重墨（w600），优雅不压封面
                fontWeight: FontWeight.w600,
              ),
            ),
            if (two && sub.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.46),
                  fontSize: 12.5,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 进度

class _ProgressSection extends ConsumerWidget {
  const _ProgressSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: PlayerProgressBar(
        // 仿网易云：进度行中央为音质标签（可点击弹音质选择）
        centerLabel: const _QualityButton(),
      ),
    );
  }
}

/// 音质标签按钮：点击弹出音质选择，切换后全队列重解析并保留进度续播
class _QualityButton extends ConsumerWidget {
  const _QualityButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AudioQuality quality = ref.watch(audioQualityProvider);
    return GestureDetector(
      onTap: () => showQualitySheet(context, quality),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.25), width: 1),
        ),
        child: Text(
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
          // 需求：去除播放/暂停白色背景 —— 双环描边 + 实心图形（网易云样式）
          _RingPlayButton(
            playing: playing,
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

/// 双环描边播放键：外环 2px + 内环 1px（半透明），中心三角/双竖条
class _RingPlayButton extends StatelessWidget {
  const _RingPlayButton({
    required this.playing,
    required this.busy,
    required this.onTap,
  });

  final bool playing;
  final bool busy;
  final VoidCallback onTap;

  static const double _size = 66;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: _size,
        height: _size,
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(18),
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                ),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder:
                    (Widget child, Animation<double> anim) => ScaleTransition(
                  scale: anim,
                  child: child,
                ),
                child: CustomPaint(
                  key: ValueKey<bool>(playing),
                  size: const Size(_size, _size),
                  painter: _RingPlayPainter(playing: playing),
                ),
              ),
      ),
    );
  }
}

class _RingPlayPainter extends CustomPainter {
  const _RingPlayPainter({required this.playing});

  final bool playing;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = size.shortestSide / 2 - 1;

    // 外环
    final Paint outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white;
    canvas.drawCircle(c, r, outer);

    // 内环（半透明）
    final Paint inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.45);
    canvas.drawCircle(c, r - 4.5, inner);

    // 中心图形：三角 / 双竖条
    final Paint fg = Paint()..color = Colors.white;
    if (playing) {
      final double barW = size.width * 0.052;
      final double barH = size.height * 0.30;
      final double gap = size.width * 0.030;
      final RRect left = RRect.fromRectAndRadius(
        Rect.fromLTWH(c.dx - gap / 2 - barW, c.dy - barH / 2, barW, barH),
        Radius.circular(barW / 2),
      );
      final RRect right = RRect.fromRectAndRadius(
        Rect.fromLTWH(c.dx + gap / 2, c.dy - barH / 2, barW, barH),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(left, fg);
      canvas.drawRRect(right, fg);
    } else {
      final double w = size.width * 0.24;
      final Path tri = Path()
        ..moveTo(c.dx - w / 2 + 1.5, c.dy - w * 0.62)
        ..lineTo(c.dx + w / 2 + 1.5, c.dy)
        ..lineTo(c.dx - w / 2 + 1.5, c.dy + w * 0.62)
        ..close();
      // 圆角三角
      final Paint triPaint = Paint()..color = Colors.white;
      canvas.drawPath(tri, triPaint);
    }
  }

  @override
  bool shouldRepaint(_RingPlayPainter oldDelegate) =>
      oldDelegate.playing != playing;
}

class _CtrlIcon extends StatelessWidget {
  const _CtrlIcon({
    required this.icon,
    required this.size,
    required this.onTap,
  });

  final IconData icon;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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

/// 播放页底部功能条：按钮集合与顺序由「播放页底部功能自定义」配置驱动。
/// 需求：不显示文字名称，长按显示气泡提示（Tooltip 默认长按触发）。
class _BottomStrip extends ConsumerWidget {
  const _BottomStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final Color tint = Colors.white.withValues(alpha: 0.75);

    final Map<String, Widget> builders = <String, Widget>{
      'output': _StripButton(
        icon: Icons.sensors_rounded,
        label: '媒体输出',
        color: tint,
        onTap: track == null ? null : () => showMediaOutputSheet(context),
      ),
      'similar': _StripButton(
        icon: Icons.graphic_eq_rounded,
        label: '相似歌曲',
        color: tint,
        onTap: track?.neteaseId == null
            ? null
            : () => showSimilarSongsSheet(context, track!),
      ),
      'wiki': _StripButton(
        icon: Icons.menu_book_rounded,
        label: '歌词百科',
        color: tint,
        onTap: track?.neteaseId == null
            ? null
            : () => context.push(
                  '/wiki/${track!.neteaseId}?title=${Uri.encodeComponent(track.title)}'
                  '&artist=${Uri.encodeComponent(track.artist)}'
                  '${track.mvId != null ? '&mv=${track.mvId}' : ''}',
                ),
      ),
      'download': const _DownloadStripButton(),
      'comments': _StripButton(
        icon: Icons.mode_comment_outlined,
        label: '评论',
        color: tint,
        onTap: track == null ? null : () => context.push('/comments', extra: track),
      ),
      'settings': _StripButton(
        icon: Icons.settings_outlined,
        label: '设置',
        color: tint,
        onTap: () => showPlayerMoreSheet(context),
      ),
    };

    final List<Widget> buttons = <Widget>[
      for (final String id in cfg.stripButtons)
        if (builders[id] != null) builders[id]!,
    ];

    return Padding(
      // 需求：底部控件位置上移（太靠近底部显得很奇怪）
      padding: EdgeInsets.fromLTRB(
          math.max(34.0 - buttons.length * 4, 16), 6, 34, 26),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: buttons.isEmpty
            ? <Widget>[const SizedBox.shrink()]
            : buttons,
      ),
    );
  }
}

/// 下载按钮（带下载中转圈状态）
class _DownloadStripButton extends ConsumerStatefulWidget {
  const _DownloadStripButton();

  @override
  ConsumerState<_DownloadStripButton> createState() =>
      _DownloadStripButtonState();
}

class _DownloadStripButtonState extends ConsumerState<_DownloadStripButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final Color tint = Colors.white.withValues(alpha: 0.75);
    return _StripButton(
      icon: Icons.download_outlined,
      label: '下载',
      color: tint,
      busy: _busy,
      onTap: track == null || _busy
          ? null
          : () async {
              setState(() => _busy = true);
              final DownloadResult r = await downloadTrack(ref, track);
              if (!context.mounted) return;
              setState(() => _busy = false);
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(r.message)));
            },
    );
  }
}

class _StripButton extends StatelessWidget {
  const _StripButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final bool disabled = onTap == null;
    final Color c = disabled ? color.withValues(alpha: 0.3) : color;
    // 需求：仅图标，长按显示气泡提示
    return Tooltip(
      message: label,
      triggerMode: TooltipTriggerMode.longPress,
      preferBelow: false,
      verticalOffset: 26,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(fontSize: 11.5, color: Colors.white),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 23, color: c),
        ),
      ),
    );
  }
}
