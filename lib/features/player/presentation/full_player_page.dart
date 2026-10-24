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
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/lyrics.dart' show LyricLine, activeLyricIndex;
import '../../../core/utils/yrc_lyrics.dart'
    show YrcLine, YrcWord, activeYrcIndex;
import '../../../core/widgets/cover_image.dart'
    show CoverImage, CoverSize, fetchBytes;
import '../../../core/widgets/marquee_text.dart';
import '../../auth/providers/auth_providers.dart';
import '../../comments/providers/comments_providers.dart'
    show songCommentCountProvider;
import '../../library/data/download_service.dart';
import '../../library/domain/track.dart';
import '../../settings/domain/settings_models.dart' show AudioQuality;
import '../../settings/providers/settings_providers.dart'
    show audioQualityProvider;
import '../domain/np_settings.dart';
import '../../../core/utils/platform_actions.dart';
import '../providers/lyrics_providers.dart'
    show ParsedLyrics, currentLyricsProvider;
import '../providers/np_settings_providers.dart';
import '../providers/player_providers.dart';
import 'player_more_sheet.dart';
import 'widgets/cover_art_view.dart' show CoverArtView, kSquareCoverRadiusRatio;
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
  @override
  void initState() {
    super.initState();
    // 需求：设置「播放页始终亮屏」—— 进入播放页按开关点亮
    // FLAG_KEEP_SCREEN_ON；开关变化实时同步；离开播放页（dispose）恢复。
    ref.listenManual(npSettingsProvider,
        (NpPlayerSettings? _, NpPlayerSettings next) {
      unawaited(PlatformActions.keepScreenOn(next.playerKeepScreenOn));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(PlatformActions.keepScreenOn(
            ref.read(npSettingsProvider).playerKeepScreenOn));
      }
    });
  }

  @override
  void dispose() {
    // 无论开关状态如何，离开播放页必须恢复自动熄屏
    unawaited(PlatformActions.keepScreenOn(false));
    super.dispose();
  }

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
        // 需求：封面页顶部显示播放来源、歌词页显示歌手（随视图切换）
        _TopBar(showLyrics: widget.showLyrics),
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
                        // 封面页歌词预览占位预留，避免溢出（kgka 移植后预览加高）
                        final double reserve = switch (widget.cfg.coverLyrics) {
                          NpCoverLyricsMode.none => 0.0,
                          NpCoverLyricsMode.one => 60.0,
                          NpCoverLyricsMode.two => 102.0,
                        };
                        final double maxCover = (cons.maxHeight - reserve)
                            .clamp(0.0, cons.maxHeight);
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
      // ⚠️ 必须重置拖动偏移：回弹结束后常规态按 _dragDx 平移渲染，
      // 残留偏移会让封面永久停在松手位置（「未切歌封面卡住」根因）
      _dragDx = 0;
    });
    _slide.forward(from: 0);
  }

  /// 切歌过渡：旧封面沿拖动方向滑出，新封面从反方向滑入；同时立即切歌
  void _startSwitch(double dx) {
    final PlayerState ps = ref.read(playerProvider);
    if (!ps.hasQueue) {
      // 无队列无法切歌：按未过阈值回弹，而不是静默返回（否则封面卡在松手位置）
      _startSpringBack(dx);
      return;
    }
    final int len = ps.queue.length;
    final bool backward = dx > 0; // 右滑 → 上一首
    _dir = backward ? 1 : -1;
    final int neighborIndex =
        backward ? (ps.index - 1 + len) % len : (ps.index + 1) % len;
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
      _dragDx = 0; // 双保险：任何路径残留的拖动偏移一并归零
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
                                ui.lerpDouble(-_dir * side, 0.0,
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
/// 圆角随 coverStyle（需求修复：方形圆角设置下，滑动回弹/切歌过渡
/// 不再一瞬间变回无圆角方形 —— 旧实现未读圆角设置）。
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
    // 与 CoverArtView 同一圆角比例（需求：方形圆角为默认样式）
    final double radius =
        style == NpCoverStyle.rounded ? size * kSquareCoverRadiusRatio : 0;
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
        child: CoverImage(
          src: cover,
          size: size,
          radius: 0,
          coverSize: CoverSize.large,
          // 切歌过渡期新封面加载时保留旧画面（无缝滑入）
          keepOldWhileLoading: true,
        ),
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
            _TopBar(showLyrics: false),
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
            _TopBar(showLyrics: true),
            Expanded(
              child: const KaraokeLyricsView(),
            ),
          ],
        );
      case NpDisplayMode.cover:
        return Column(
          children: <Widget>[
            _TopBar(showLyrics: false),
            Expanded(child: coverColumn),
          ],
        );
    }
  }
}

// ---------------------------------------------------------------- 顶部栏

/// 仿网易云顶栏：收起 + 居中显示（需求：封面页时显示歌曲播放来源）
///  - 封面页：显示「播放来源」（队列名，如歌单名/缓存音乐），
///    无来源时回退歌手名；
///  - 歌词页：保持显示歌手名（对齐网易云歌词页习惯）。
class _TopBar extends ConsumerWidget {
  const _TopBar({this.showLyrics = false});

  /// 当前是否处于歌词视图（决定顶部显示来源还是歌手）
  final bool showLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? title =
        ref.watch(playerProvider.select((PlayerState s) => s.queueTitle));
    // 需求：封面页时顶部显示的歌曲歌手改成「歌曲播放来源」——
    // 来源 = 当前播放队列名（歌单名/缓存音乐/搜索播放等），
    // 无队列来源时回退歌手名；歌词页保持歌手名。
    final String center = showLyrics
        ? ((track?.artist.isNotEmpty ?? false)
            ? track!.artist
            : (title ?? 'MingMusic'))
        : ((title != null && title.isNotEmpty)
            ? title
            : ((track?.artist.isNotEmpty ?? false)
                ? track!.artist
                : 'MingMusic'));

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
        ref.watch(
            authProvider.select((AuthState s) => s.likedIds.contains(songId)));

    return Padding(
      // 需求：底部区域呼吸感修复 —— 信息区与进度条不再挤在一起；
      // 本批需求「继续上移进度条与上方信息」：上/下边距再度收紧
      padding: const EdgeInsets.fromLTRB(24, 3, 12, 2),
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
                      // 需求：VIP 样式 —— 透明背景 + 白字 + 白色圆角描边
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.85),
                            width: 1,
                          ),
                        ),
                        child: const Text(
                          'VIP',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            height: 1.2,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
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
        cursor:
            widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
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
        size.width / 2 - s * 1.1,
        size.height / 2 - s * 0.45,
        size.width / 2 - s * 0.34,
        size.height / 2 - s * 1.05,
        size.width / 2,
        size.height / 2 - s * 0.42,
      )
      ..cubicTo(
        size.width / 2 + s * 0.34,
        size.height / 2 - s * 1.05,
        size.width / 2 + s * 1.1,
        size.height / 2 - s * 0.45,
        size.width / 2,
        size.height / 2 + s * 0.32,
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
      onTap: () =>
          context.push('/mv/$mvId?title=${Uri.encodeComponent(title)}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
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

/// 封面页歌词预览（需求：完全仿照 kgka_Music_hl 封面播放页）：
///  - 主行：当前播放行大字白色（22px/w900），左对齐；
///    原文有逐字歌词（yrc）→ 逐字播放动画（[_KaraokeText] 卡拉OK渐进）；
///    无逐字 → 跑马灯防溢出；
///  - 副行（固定规则，不随「显示翻译」设置变化）：
///    翻译/音译存在 → 一行原文一行翻译（非中文歌）；
///    无翻译 → 下一非空行（中文歌显示两行原文）；
///  - 一行/两行两种模式，默认一行；无歌词时显示占位避免布局跳动；
///  - 换行时 AnimatedSwitcher 平滑过渡（对齐 kgka 260ms）。
class _CoverLyricsPreview extends ConsumerWidget {
  const _CoverLyricsPreview({required this.mode, required this.width});

  final NpCoverLyricsMode mode;
  final double width;

  /// 解析当前行：主行（逐字/普通）+ 副行 + 主行时间戳（滚动切换 key）。
  ///
  /// 需求（kgka_Music_hl 对齐）：
  ///  - 双行模式副行规则（不随「显示翻译」设置变化）：
  ///    翻译/音译存在时显示翻译 —— 非中文歌 = 一行原文 + 一行翻译；
  ///    无翻译时显示下一非空行 —— 中文歌 = 两行原文；
  ///  - 原文（主行）有逐字歌词（yrc）时主行走逐字播放动画（[_KaraokeText]），
  ///    无逐字（LRC / 元数据行 / 空行）回退跑马灯。
  ({YrcLine? karaoke, String main, String sub, int mainTime}) _resolve(
      ParsedLyrics lyrics, Duration position) {
    if (lyrics.hasYrc) {
      final int idx = activeYrcIndex(lyrics.yrcLines, position);
      if (idx < 0) return (karaoke: null, main: '', sub: '', mainTime: -1);
      final YrcLine cur = lyrics.yrcLines[idx];
      String sub = '';
      if (!cur.isMetadata) {
        // 副行：翻译/音译优先（非中文带翻译 → 一行原文一行翻译）
        final String t = lyrics.subLineFor(cur.start.inMilliseconds);
        if (t.isNotEmpty) {
          sub = t;
        } else {
          // 无翻译（中文歌）→ 显示下一非空、非元数据行（两行原文）
          for (int j = idx + 1; j < lyrics.yrcLines.length; j++) {
            final YrcLine nx = lyrics.yrcLines[j];
            if (!nx.isMetadata && nx.text.trim().isNotEmpty) {
              sub = nx.text;
              break;
            }
          }
        }
      }
      return (
        karaoke: cur.isMetadata || cur.words.isEmpty ? null : cur,
        main: cur.text,
        sub: sub,
        mainTime: cur.start.inMilliseconds,
      );
    }
    final int idx = activeLyricIndex(lyrics.lrcLines, position);
    if (idx < 0) return (karaoke: null, main: '', sub: '', mainTime: -1);
    final LyricLine cur = lyrics.lrcLines[idx];
    String sub = '';
    final String t = lyrics.subLineFor(cur.time.inMilliseconds);
    if (t.isNotEmpty) {
      sub = t;
    } else {
      // LRC 行同理：无翻译显示下一非空行
      for (int j = idx + 1; j < lyrics.lrcLines.length; j++) {
        final String txt = lyrics.lrcLines[j].text;
        if (txt.trim().isNotEmpty) {
          sub = txt;
          break;
        }
      }
    }
    return (
      karaoke: null,
      main: cur.text,
      sub: sub,
      mainTime: cur.time.inMilliseconds
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ParsedLyrics lyrics = ref.watch(currentLyricsProvider);
    final Duration position =
        ref.watch(positionProvider).value ?? Duration.zero;

    final bool two = mode == NpCoverLyricsMode.two;
    final double height = two ? 78 : 40;

    if (lyrics.isEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '暂无歌词',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    final ({YrcLine? karaoke, String main, String sub, int mainTime}) line =
        _resolve(lyrics, position);
    final String main = line.main.isEmpty ? '···' : line.main;
    final String sub = two ? line.sub : '';
    final bool useKaraoke = line.karaoke != null && line.main.isNotEmpty;

    return SizedBox(
      width: width,
      height: height,
      // 第十三批需求：封面页歌词随播放自动滚动 —— 主/副行独立滚动
      // 切换（新行从下方滑入把旧行顶上去），逐字行动画不被打断
      //（行不变时 key 不变，AnimatedSwitcher 不重建）。
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 主行：当前行大字（kgka：22px / w900 / height 1.22）；
          // 有逐字歌词 → 逐字播放动画（需求）
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> anim) =>
                _rollTransition(child, anim, ValueKey<int>(line.mainTime)),
            child: SizedBox(
              key: ValueKey<int>(line.mainTime),
              height: 30,
              width: width,
              child: useKaraoke
                  ? _KaraokeText(line: line.karaoke!)
                  : MarqueeText(
                      main,
                      textAlign: TextAlign.left,
                      velocity: 32,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        height: 1.22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ),
          if (two && sub.isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            // 副行：翻译优先，否则下一行（kgka：16px / w700 / 白 46%）
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> anim) =>
                  _rollTransition(child, anim, ValueKey<String>(sub)),
              child: Text(
                sub,
                key: ValueKey<String>(sub),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.46),
                  fontSize: 16,
                  height: 1.18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 封面页歌词预览的滚动切换过渡（第十三批需求：自动滚动效果）——
/// 新行从下方滑入淡入，旧行向上滑出淡出；[currentKey] 用于区分
/// 进入/退出行（退出方向反转形成上滚视觉）。裁剪防止相邻行溢出。
Widget _rollTransition(
  Widget child,
  Animation<double> anim,
  Key currentKey,
) {
  final bool isIncoming = child.key == currentKey;
  final Tween<Offset> slide = Tween<Offset>(
    begin: isIncoming ? const Offset(0, 0.55) : const Offset(0, -0.55),
    end: Offset.zero,
  );
  return ClipRect(
    child: FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: slide.animate(anim),
        child: child,
      ),
    ),
  );
}

/// 逐字卡拉OK主行（需求：原文有逐字歌词时封面页歌词需有逐字播放动画）。
///
/// 实现：同排版双层文本叠加 —— 底层未唱色（白 40%）、顶层已唱色（白），
/// 顶层按「已唱像素宽度」ClipRect 裁剪，像素级平滑推进；
/// 进度 = positionProvider 流（200ms 粒度）+ Ticker 每帧向未来线性外推
/// （播放中每帧推进，暂停停在流位置）；排版与逐字 x 区间按行文本缓存，
/// 行不变不重排 —— 每帧开销仅为一次宽度裁剪更新。
class _KaraokeText extends ConsumerStatefulWidget {
  const _KaraokeText({required this.line});

  final YrcLine line;

  @override
  ConsumerState<_KaraokeText> createState() => _KaraokeTextState();
}

class _KaraokeTextState extends ConsumerState<_KaraokeText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// 最近一次流位置与其到达时刻（Ticker 外推基准）
  Duration _streamPos = Duration.zero;
  DateTime _streamAt = DateTime.now();

  // 排版缓存（行文本不变时复用，避免每帧重排）
  TextPainter? _painter;
  List<Rect>? _boxes;
  String? _layoutKey;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((Duration _) {
      if (mounted) setState(() {});
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _painter?.dispose();
    _painter = null;
    super.dispose();
  }

  void _ensureLayout(TextStyle style) {
    final String key = '${widget.line.text}'
        '|${style.fontSize}|${style.fontWeight?.value ?? 0}';
    if (_layoutKey == key && _painter != null) return;
    _layoutKey = key;
    _painter?.dispose();
    final TextPainter tp = TextPainter(
      text: TextSpan(text: widget.line.text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    // 每个 word 在整行中的 x 区间（与 words 顺序一一对应）
    final List<Rect> boxes = <Rect>[];
    int offset = 0;
    for (final YrcWord w in widget.line.words) {
      final int end = math.min(offset + w.text.length, widget.line.text.length);
      final List<TextBox> hb = offset < end
          ? tp.getBoxesForSelection(
              TextSelection(baseOffset: offset, extentOffset: end))
          : const <TextBox>[];
      boxes.add(hb.isNotEmpty ? hb.first.toRect() : Rect.zero);
      offset = end;
    }
    _painter = tp;
    _boxes = boxes;
  }

  /// 已唱像素宽度（当前字内按时间进度线性展开）
  double _sungWidth(Duration pos) {
    final List<Rect>? boxes = _boxes;
    if (boxes == null) return 0;
    double width = 0;
    final List<YrcWord> words = widget.line.words;
    for (int i = 0; i < words.length; i++) {
      final YrcWord w = words[i];
      final Rect box = boxes[i];
      if (box == Rect.zero) continue; // 空格等无字形区间
      if (pos >= w.end) {
        width = box.right;
      } else if (pos > w.start) {
        return box.left + (box.right - box.left) * w.progress(pos);
      } else {
        break;
      }
    }
    return width;
  }

  @override
  Widget build(BuildContext context) {
    // 流位置更新（200ms 粒度）：listen 只更新外推基准，不触发重建；
    // 重绘由 Ticker 驱动（播放中每帧推进）
    ref.listen<AsyncValue<Duration>>(positionProvider,
        (AsyncValue<Duration>? _, AsyncValue<Duration> v) {
      final Duration? p = v.value;
      if (p != null) {
        _streamPos = p;
        _streamAt = DateTime.now();
      }
    });
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    // 暂停时停表（省电），恢复播放时重启
    if (playing && !_ticker.isActive) _ticker.start();
    if (!playing && _ticker.isActive) _ticker.stop();

    const TextStyle style = TextStyle(
      color: Colors.white,
      fontSize: 22,
      height: 1.22,
      fontWeight: FontWeight.w900,
    );
    _ensureLayout(style);

    final Duration pos = playing
        ? _streamPos + DateTime.now().difference(_streamAt)
        : _streamPos;

    return ClipRect(
      child: Stack(
        alignment: Alignment.centerLeft,
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          // 未唱层：整行白 40%
          Text(
            widget.line.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: style.copyWith(color: Colors.white.withValues(alpha: 0.4)),
          ),
          // 已唱层：白色，按已唱像素宽度揭示
          ClipRect(
            clipper: _WidthClipper(width: _sungWidth(pos)),
            child: Text(
              widget.line.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡拉OK已唱部分揭示裁剪（按宽度）
class _WidthClipper extends CustomClipper<Rect> {
  const _WidthClipper({required this.width});

  final double width;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, width, size.height);

  @override
  bool shouldReclip(_WidthClipper oldClipper) => oldClipper.width != width;
}

// ---------------------------------------------------------------- 进度

class _ProgressSection extends ConsumerWidget {
  const _ProgressSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 需求：进度区与上下区块拉开呼吸距离；
    // 本批需求「继续上移进度条与上方信息」：纵向留白 6 → 2
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: PlayerProgressBar(
        // 仿网易云：进度行中央为音质标签（可点击弹音质选择）
        centerLabel: const _QualityButton(),
      ),
    );
  }
}

/// 音质标签按钮：点击弹出音质选择，切换后全队列重解析并保留进度续播。
/// 第十三批需求：只显示音质名（标准/较高/极高/无损，去掉「音质」后缀），
/// 短文案也进一步降低进度行中央标签的宽度变化感。
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
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1),
        ),
        child: Text(
          switch (quality) {
            AudioQuality.standard => '标准',
            AudioQuality.higher => '较高',
            AudioQuality.exhigh => '极高',
            AudioQuality.lossless => '无损',
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
      // 需求：控制键与上方音质标签行拉开间距；本批继续上移收紧 8 → 4
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
                transitionBuilder: (Widget child, Animation<double> anim) =>
                    ScaleTransition(
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
      'volume': const _VolumeStripButton(),
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
        onTap: track == null
            ? null
            : () => context.push('/comments', extra: track),
      ),
      'settings': _StripButton(
        icon: Icons.settings_outlined,
        label: '设置',
        color: tint,
        onTap: () => showPlayerMoreSheet(context),
      ),
    };

    // 需求：音量条独占模式 —— 勾选「音量条」后底部只保留
    // 音量条 + 设置键（音量条在设置键左侧，Expanded 拉伸）。
    if (cfg.stripButtons.contains('volume')) {
      return Padding(
        // 第十三批需求：进度条以上控件区继续上移 —— 底边距 28 → 38
        padding: const EdgeInsets.fromLTRB(24, 2, 18, 38),
        child: Row(
          children: <Widget>[
            const Expanded(child: _VolumeStripButton()),
            const SizedBox(width: 6),
            builders['settings']!,
          ],
        ),
      );
    }

    final List<Widget> buttons = <Widget>[
      for (final String id in cfg.stripButtons)
        if (builders[id] != null && id != 'volume') builders[id]!,
    ];

    return Padding(
      // 需求：底部控件位置继续上移（第十三批：进度条以上的控件区仍
      // 偏低 —— 底边距 28 → 38，整层浮层再度抬高，信息区/进度条/控制键
      // 随之上移）
      padding: EdgeInsets.fromLTRB(
          math.max(34.0 - buttons.length * 4, 16), 2, 34, 38),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: buttons.isEmpty ? <Widget>[const SizedBox.shrink()] : buttons,
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

/// 音量条底部按键（需求：与进度条样式一致的自绘圆角条）：
///  - 静音图标 + 音量条（双层圆角条：底条白 25%，已调白 90%，同高度）；
///  - 拖动时条平滑变粗（与 PlayerProgressBar 手感一致）；
///  - 左侧静音/取消静音切换键。
class _VolumeStripButton extends ConsumerStatefulWidget {
  const _VolumeStripButton();

  @override
  ConsumerState<_VolumeStripButton> createState() => _VolumeStripButtonState();
}

class _VolumeStripButtonState extends ConsumerState<_VolumeStripButton> {
  double _volume = 1.0;
  bool _dragging = false;
  double? _restoreVolume;

  static const double _kRestHeight = 4;
  static const double _kDragHeight = 8;

  @override
  void initState() {
    super.initState();
    _volume = ref.read(audioHandlerProvider).player.volume;
  }

  void _apply(double v) {
    setState(() => _volume = v.clamp(0.0, 1.0));
    ref.read(audioHandlerProvider).player.setVolume(_volume);
  }

  void _toggleMute() {
    if (_volume > 0) {
      _restoreVolume = _volume;
      _apply(0);
    } else {
      _apply(_restoreVolume ?? 1.0);
    }
  }

  IconData get _icon => _volume <= 0
      ? Icons.volume_off_rounded
      : _volume < 0.5
          ? Icons.volume_down_rounded
          : Icons.volume_up_rounded;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        GestureDetector(
          onTap: _toggleMute,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(_icon,
                size: 22, color: Colors.white.withValues(alpha: 0.75)),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails d) =>
                _applyFromBox(context, d.globalPosition.dx),
            onHorizontalDragStart: (DragStartDetails d) {
              setState(() => _dragging = true);
              _applyFromBox(context, d.globalPosition.dx);
            },
            onHorizontalDragUpdate: (DragUpdateDetails d) =>
                _applyFromBox(context, d.globalPosition.dx),
            onHorizontalDragEnd: (_) => setState(() => _dragging = false),
            child: TweenAnimationBuilder<double>(
              tween:
                  Tween<double>(end: _dragging ? _kDragHeight : _kRestHeight),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              builder: (BuildContext ctx, double h, _) {
                return SizedBox(
                  height: 26,
                  child: Center(
                    child: _VolumeBar(
                      value: _volume,
                      height: h,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _applyFromBox(BuildContext ctx, double globalDx) {
    final RenderBox? box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // 排除左侧图标宽度（图标 22 + padding 12 + gap 2 ≈ 36）
    const double leading = 36;
    final double w = math.max(1.0, box.size.width - leading);
    final double v =
        ((globalDx - box.globalToLocal(Offset.zero).dx) - leading) / w;
    _apply(v);
  }
}

/// 音量条本体（双层圆角条，观感与 PlayerProgressBar 完全一致）
class _VolumeBar extends StatelessWidget {
  const _VolumeBar({required this.value, required this.height});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints cons) {
        final double w = cons.maxWidth;
        final double filled = (w * value.clamp(0.0, 1.0));
        return SizedBox(
          width: w,
          height: height,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: <Widget>[
              // 总条（底）
              Container(
                width: w,
                height: height,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              // 当前进度条（与总条同高同大，Apple Music 观感）
              Container(
                width: math.max(height, filled),
                height: height,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
