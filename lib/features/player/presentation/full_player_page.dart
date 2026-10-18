/// 全屏播放页（仿网易云/Zephyr-Music，支持高度自定义）：
///
///  - 显示模式（NpDisplayMode）：自适应（平板双列 / 手机可切换）/ 仅封面 / 仅歌词；
///  - 封面区：横向 PageView 轮播（左右滑动直接切歌，相邻封面进入页面）；
///    封面 Hero 与 Mini 播放条同 tag —— 路由转场时无缝放大，配合背景模糊渐入；
///  - 方形封面：播放时保持尺寸，暂停时明显缩小（缩放幅度 10%）；
///  - 歌词页：单击切换封面/歌词；双击歌词行 seek；左右滑切歌；
///  - 播放键：双环描边样式（无白色填充底）；
///  - 红心：喜欢切换 + 可选迸发动效（heartEffect）；
///  - 底部功能条：按「播放页底部功能自定义」勾选渲染（媒体输出/相似歌曲/
///    歌词百科/下载/评论/设置），长按气泡提示；设置 → 播放页自定义底部菜单；
///  - 手势：下滑收起播放页。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
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
  /// 封面轮播控制器（相邻封面进入页面，对齐网易云样式）
  PageController? _pageCtrl;

  @override
  void dispose() {
    _pageCtrl?.dispose();
    super.dispose();
  }

  double _coverSize(BuildContext context) {
    final double h = MediaQuery.sizeOf(context).height;
    final double w = MediaQuery.sizeOf(context).width;
    return (h * (widget.showLyrics ? 0.36 : 0.42)).clamp(200.0, w * 0.88);
  }

  @override
  Widget build(BuildContext context) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final PlayerState ps = ref.watch(playerProvider);
    final int index = ps.index;
    final int queueLen = ps.queue.length;

    // 内核下标变化（按钮/通知切歌）→ 轮播跟随动画；用户滑动场景中
    // onPageChanged → playAt 已把 index 同步到当前页，差值 < 1 不会回拽
    if (!widget.showLyrics && queueLen > 0) {
      final PageController ctrl = _ensureCtrl(queueLen, index);
      if (ctrl.hasClients &&
          ctrl.positions.isNotEmpty &&
          (ctrl.page! - index).abs() >= 0.999) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _pageCtrl == null || !_pageCtrl!.hasClients) return;
          if ((_pageCtrl!.page! - index).abs() < 0.01) return;
          _pageCtrl!.animateToPage(
            index.clamp(0, queueLen - 1),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          );
        });
      }
    }

    final Widget trackContent = Column(
      children: <Widget>[
        // 上半区：封面轮播 ⇄ 歌词
        Expanded(
          child: AnimatedSwitcher(
            duration: AppConstants.playerPageFlip,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> anim) =>
                FadeTransition(opacity: anim, child: child),
            child: widget.showLyrics
                ? SizedBox(
                    key: const ValueKey<String>('lyrics'),
                    width: double.infinity,
                    // 单击歌词区域切换视图；歌词区左右滑切歌由页面级手势接管
                    child: KaraokeLyricsView(
                      key: const ValueKey<String>('lyrics-view'),
                      onToggleView: widget.onToggleLyrics,
                    ),
                  )
                : SizedBox(
                    key: const ValueKey<String>('cover'),
                    width: double.infinity,
                    child: _CoverCarousel(
                      cfg: cfg,
                      size: _coverSize(context),
                    ),
                  ),
          ),
        ),
        _InfoSection(),
        const _ProgressSection(),
        const _ControlBar(),
        const _BottomStrip(),
      ],
    );

    return Column(
      children: <Widget>[
        const _TopBar(),
        Expanded(child: trackContent),
      ],
    );
  }

  PageController _ensureCtrl(int len, int index) {
    _pageCtrl ??= PageController(
      viewportFraction: 0.84,
      initialPage: index.clamp(0, len - 1),
    );
    return _pageCtrl!;
  }
}

/// 封面轮播：每页一首歌的封面（支持黑胶/方形/圆形样式），左右滑切歌
class _CoverCarousel extends ConsumerWidget {
  const _CoverCarousel({required this.cfg, required this.size});

  final NpPlayerSettings cfg;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerState ps = ref.watch(playerProvider);
    final int len = ps.queue.length;
    if (len == 0) return const SizedBox.shrink();
    final _PhoneBodyState? host =
        context.findAncestorStateOfType<_PhoneBodyState>();
    final PageController ctrl = host!._ensureCtrl(len, ps.index);

    return PageView.builder(
      controller: ctrl,
      itemCount: len,
      onPageChanged: (int page) {
        if (page == ps.index) return;
        ref.read(playerProvider.notifier).playAt(page);
      },
      itemBuilder: (BuildContext context, int i) {
        final Track t = ps.queue[i];
        final bool current = i == ps.index;
        return Center(
          child: CoverArtView(
            style: cfg.coverStyle,
            cover: t.cover,
            playing: current ? ps.playing : false,
            size: size,
            scale: cfg.coverScale,
            shadow: cfg.coverShadow,
            squareRadius: cfg.squareCoverRadius,
            // 非当前页封面不可长按（避免误触查看错误封面）
            onLongPress: t.cover == null || !current
                ? null
                : () => showCoverViewer(
                      context,
                      cover: t.cover,
                      title: '${t.title} - ${t.artist}',
                    ),
          ),
        );
      },
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

class _InfoSection extends ConsumerWidget {
  const _InfoSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final bool vip = track?.isVipOnly ?? false;
    final TextTheme theme = Theme.of(context).textTheme;

    return Padding(
      // 需求：歌曲名称和歌手名称往下移动一点
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
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
              // MV 闭环入口：歌曲带 MV 时展示胶囊，点击进入 MV 播放页
              if (track?.mvId != null) ...<Widget>[
                const SizedBox(width: 8),
                _MvPill(mvId: track!.mvId!, title: track.title),
              ],
            ],
          ),
          const SizedBox(height: 5),
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

// ---------------------------------------------------------------- 喜欢/评论计数行

/// 仿网易云：标题下方右侧 喜欢 + 评论数（点击评论跳转评论页）
class _CountsRow extends ConsumerStatefulWidget {
  const _CountsRow();

  @override
  ConsumerState<_CountsRow> createState() => _CountsRowState();
}

class _CountsRowState extends ConsumerState<_CountsRow> {
  /// 红心迸发动效触发器
  bool _burst = false;

  @override
  Widget build(BuildContext context) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    if (track == null) return const SizedBox.shrink();
    final int? songId = track.neteaseId;
    final int count = songId == null
        ? 0
        : ref.watch(songCommentCountProvider(songId)).value ?? 0;
    final bool liked = (songId ?? 0) > 0 &&
        ref.watch(authProvider
            .select((AuthState s) => s.likedIds.contains(songId)));
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final Color tint = Colors.white.withValues(alpha: 0.78);

    return Row(
      children: <Widget>[
        const Spacer(),
        // 喜欢（服务器红心，乐观更新）
        GestureDetector(
          onTap: () async {
            if (songId == null || songId == 0) return;
            final String? error = await ref
                .read(authProvider.notifier)
                .toggleLikeSong(songId);
            if (!context.mounted) return;
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
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Icon(
                liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: 20,
                color: liked ? AppConstants.brandColor : tint,
              ),
              if (_burst)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _HeartBurst(
                      color: AppConstants.brandColor,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 18),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push('/comments', extra: track),
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

  /// 仿网易云计数：千以内原样，万以上「x万+」
  static String _formatWan(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(0)}亿+';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(0)}万+';
    return '$n';
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

/// MV 胶囊按钮（歌曲详情 mv 字段非零时展示，闭环：/mv/url + /mv/detail 播放页）
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
        decoration: BoxDecoration(
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.45), width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.play_circle_outline_rounded,
                size: 13, color: Colors.white.withValues(alpha: 0.85)),
            const SizedBox(width: 3),
            Text(
              'MV',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
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
      padding: EdgeInsets.fromLTRB(
          math.max(34.0 - buttons.length * 4, 16), 4, 34, 12),
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
