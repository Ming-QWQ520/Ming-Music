/// Mini 播放条（需求：紧凑极简嵌入导航栏，其余样式悬浮导航栏上方）：
///
/// 布局模式（NpPlayerSettings.miniStyle）：
///  - compact 紧凑极简：**嵌入底部导航栏「发现 ⇄ 我的」中间**（需求），
///    像 kgka_Music_hl 那样**只显示歌曲封面**，周围显示歌曲进度（圆环），
///    点击主体进全屏；
///  - classic / overlay / wide：**悬浮于导航栏上方**（需求：维持之前的
///    设计），背景与边框全透明（无 Material 底色 / 无描边），带控制键：
///    · classic：封面 + 单行「歌名 - 歌手」 + 播放键 + 列表键
///      （需求：经典样式播放键周围无进度条显示）；
///    · overlay：封面作背景 + 渐变压暗 + 标题叠印 + 播放键 + 列表键；
///    · wide：封面 + 歌名/歌手双行 + 播放键 + 列表键 + 底部细进度线。
///
/// 通用：
///  - 进度：圆环仅在紧凑极简模式绕封面显示（顶部中心起点，顺时针）；
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

/// 主骨架用：当前样式是否嵌入底部导航栏（需求：仅紧凑极简嵌入）
bool miniInNavBar(MiniPlayerStyle style) => style == MiniPlayerStyle.compact;

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key, this.embedded = false});

  /// true = 渲染为导航栏中央形态（紧凑布局）；false = 悬浮完整条
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool hasQueue = ref.watch(hasQueueProvider);
    if (!hasQueue) return const SizedBox.shrink();

    final MiniPlayerStyle style = ref.watch(
        npSettingsProvider.select((NpPlayerSettings s) => s.miniStyle));

    if (embedded) {
      // 导航栏中央槽位：紧凑极简布局（需求）
      return const _NavCompact();
    }
    // 悬浮条：classic / overlay / wide（紧凑极简不会走到这里）
    return switch (style) {
      MiniPlayerStyle.classic => const _FloatClassic(),
      MiniPlayerStyle.overlay => const _FloatOverlay(),
      MiniPlayerStyle.wide => const _FloatWide(),
      MiniPlayerStyle.compact => const _FloatClassic(),
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

// ---------------------------------------------------------------- 通用按钮

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

// ------------------------------------------------------- 导航栏中央（紧凑极简）

/// 紧凑极简嵌入导航栏（需求：像 kgka_Music_hl 那样只显示歌曲封面，
/// 周围显示歌曲进度）—— 仅封面 + 圆环进度，无播放/列表键，
/// 点击主体进全屏。
class _NavCompact extends ConsumerWidget {
  const _NavCompact();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return GestureDetector(
      onTap: () => openFullPlayer(context),
      child: SizedBox(
        width: 46,
        height: 46,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            const Positioned.fill(
                child: Padding(
              padding: EdgeInsets.all(2),
              child: _MiniRingProgress(stroke: 2),
            )),
            Hero(
              tag: heroTagOf(cover),
              child: CoverImage(src: cover, size: 38, radius: 19),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 悬浮条公共

/// 切歌时内容淡入刷新（flutter_animate）
Widget _navAnimated(Widget child, Object key) => child
    .animate(key: ValueKey<Object>(key))
    .fadeIn(duration: 260.ms, curve: Curves.easeOut)
    .slideY(begin: 0.05, end: 0, duration: 260.ms, curve: Curves.easeOut);

/// 封面（Hero），供各悬浮样式复用；紧凑极简之外的悬浮条无进度环
/// （需求：经典样式播放键周围无进度条 —— 圆环仅保留给紧凑极简绕封面）
class _FloatCover extends ConsumerWidget {
  const _FloatCover({this.size = 46});

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

    return GestureDetector(
      onTap: () => openFullPlayer(context),
      child: SizedBox(
        width: size,
        height: size,
        child: image,
      ),
    );
  }
}

// ---------------------------------------------------------------- 悬浮：经典条

/// 样式 1（悬浮版）：封面 + 单行「歌名 - 歌手」+ 播放键 + 列表键。
/// 需求：背景与边框全透明（无 Material 底色、无描边、无阴影）；
/// 播放键周围无进度条显示（本样式无任何进度环/进度线）。
class _FloatClassic extends ConsumerWidget {
  const _FloatClassic();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
      child: Row(
        children: <Widget>[
          const _FloatCover(),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openFullPlayer(context),
              child: _navAnimated(
                Text(
                  track == null ? '未在播放' : '${track.title} - ${track.artist}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                track?.id ?? 'empty',
              ),
            ),
          ),
          const _MiniPlayButton(size: 40, iconSize: 22, showRing: false),
          const _MiniQueueButton(size: 36, iconSize: 21),
        ],
      ),
    );
  }
}

/// 样式 2（悬浮版）：封面铺满（圆形裁剪）+ 渐变压暗 + 标题叠印 + 控制键
class _FloatOverlay extends ConsumerWidget {
  const _FloatOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
      child: Row(
        children: <Widget>[
          GestureDetector(
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
                            colors: <Color>[
                              Color(0x59000000),
                              Color(0xCC000000)
                            ],
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
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openFullPlayer(context),
              child: Text(
                '${track?.title ?? '未在播放'} · ${track?.artist ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const _MiniPlayButton(size: 40, iconSize: 22, showRing: false),
          const _MiniQueueButton(size: 36, iconSize: 21),
        ],
      ),
    );
  }
}

/// 样式 3（悬浮版）：封面+圆环 + 歌名/歌手双行 + 控制键 + 底部细进度线
class _FloatWide extends ConsumerWidget {
  const _FloatWide();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const _FloatCover(size: 42),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => openFullPlayer(context),
                  child: _navAnimated(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          track?.title ?? '未在播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                        Text(
                          track?.artist ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                    track?.id ?? 'empty',
                  ),
                ),
              ),
              const _MiniPlayButton(size: 40, iconSize: 22, showRing: false),
              const _MiniQueueButton(size: 36, iconSize: 21),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
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
