/// Mini 播放条（需求重构：样式预设只保留「经典条」与「紧凑极简」，
/// 封面铺满/宽幅双行等其它样式全部移除；两种样式均带液态玻璃）：
///
///  - classic 经典条：无色液态玻璃圆角长条，悬浮导航栏上方 ——
///    左圆形封面 + 单行「歌名 - 歌手」+ 进度圆环播放键 + 播放列表键；
///  - compact 紧凑极简：**嵌入底部导航栏「发现 ⇄ 我的」中间**（需求不变），
///    只显示歌曲封面，周围显示歌曲进度（圆环），点击主体进全屏；
///  - 需求追加：底板无色 65% 透明，颜色/透明度可在设置自定义；
///    出现时向上移动放大、消失时向下移动缩小（MiniBarSwitcher）；
///  - 进度：需求「无论任何样式都需显示进度」—— 经典条=播放键外圈圆环，
///    紧凑极简=封面周围圆环；
///  - `select` 只订阅 playing / currentTrack / hasQueue，进度环独立订阅；
///  - 封面 Hero：与全屏播放页同 tag，路由转场无缝放大。
library;

import 'dart:math' as math;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/router.dart' show openFullPlayer;
import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../domain/np_settings.dart';
import '../../../settings/providers/settings_providers.dart'
    show glassEnabledProvider;
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

    if (embedded) {
      // 导航栏中央槽位：紧凑极简布局（需求）
      return const _NavCompact();
    }
    // 悬浮条：classic（紧凑极简不会走到这里）
    return const _FloatClassic();
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
      ..color = Colors.white.withValues(alpha: 0.92);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, fg);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.stroke != stroke;
}

// ---------------------------------------------------------------- 出入动画

/// Mini 条统一出现/消失动画（需求：消失时向下移动缩小，出现时向上移动放大）：
///  - 出现：从下方 1.35 倍高度处上滑 + 0.72 → 1.0 放大，easeOutCubic；
///  - 消失：反向播放（下滑 + 缩小），easeInCubic；
///  - AnimatedSwitcher 同时驱动新旧 child，退出动画期间旧条仍在移动，
///    不会闪没。全局宿主（app.dart）与主骨架悬浮条共用。
class MiniBarSwitcher extends StatelessWidget {
  const MiniBarSwitcher({
    super.key,
    required this.visible,
    required this.child,
  });

  /// false 时收起（向下缩小退出）；true 时展开（向上放大进入）
  final bool visible;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> anim) {
        // 进出共用一套插值：进入 0→1（上滑放大），退出 1→0（下滑缩小）
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1.35),
            end: Offset.zero,
          ).animate(anim),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.72, end: 1).animate(anim),
            child: child,
          ),
        );
      },
      child: visible
          ? KeyedSubtree(key: const ValueKey<bool>(true), child: child)
          : const SizedBox.shrink(key: ValueKey<bool>(false)),
    );
  }
}

// ---------------------------------------------------------------- 通用按钮

/// 进度圆环播放键（需求：参考图右侧为圆形播放按钮 + 进度环）
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
                  color: Colors.white,
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
        icon: Icon(Icons.queue_music_rounded,
            size: iconSize, color: Colors.white),
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

// ---------------------------------------------------------------- 悬浮：经典条

/// 切歌时内容淡入刷新（flutter_animate）
Widget _navAnimated(Widget child, Object key) => child
    .animate(key: ValueKey<Object>(key))
    .fadeIn(duration: 260.ms, curve: Curves.easeOut)
    .slideY(begin: 0.05, end: 0, duration: 260.ms, curve: Curves.easeOut);

/// 经典条（需求重构：无色液态玻璃圆角长条，颜色/透明度可自定义）：
///  - 左侧圆形封面；
///  - 中间单行「歌名 - 歌手」；
///  - 右侧进度圆环播放键 + 播放列表键；
///  - 底板：液态玻璃（BackdropFilter 模糊 + 白描边高光），
///    性能红线允许（BackdropFilter 仅 Mini 条与底部 Sheet）。
class _FloatClassic extends ConsumerWidget {
  const _FloatClassic();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? cover = track?.cover;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: _GlassBarPanel(
        child: Row(
          children: <Widget>[
            // 左：圆形封面（Hero，点击进全屏）
            GestureDetector(
              onTap: () => openFullPlayer(context),
              child: Hero(
                tag: heroTagOf(cover),
                child: CoverImage(src: cover, size: 44, radius: 22),
              ),
            ),
            const SizedBox(width: 10),
            // 中：单行「歌名 - 歌手」（点击进全屏）
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
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  track?.id ?? 'empty',
                ),
              ),
            ),
            // 右：进度圆环播放键 + 播放列表键
            const _MiniPlayButton(size: 40, iconSize: 22, showRing: true),
            const _MiniQueueButton(size: 36, iconSize: 21),
          ],
        ),
      ),
    );
  }
}

/// 无色液态玻璃面板（需求：不带颜色，65% 透明；颜色/透明度可在设置自定义）。
/// 第十一批需求：低液态玻璃高透明 —— 投影与描边大幅弱化
/// （旧实现 black 0.20~0.36 / blur 18 在高透明底上形成一圈明显"黑边"）；
/// 玻璃关闭时降级为半透明深色底（非高不透明黑板）。
class _GlassBarPanel extends ConsumerWidget {
  const _GlassBarPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool glass = ref.watch(glassEnabledProvider);
    final NpPlayerSettings np = ref.watch(npSettingsProvider);

    // 需求：无色（白玻璃中性底）默认，可自定义底色；
    // 填充不透明度 = 1 - 透明度（默认 65% 透明 → 0.35 alpha）
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color tint = np.miniColor != null
        ? Color(np.miniColor!)
        : (dark ? const Color(0xFF1A1626) : Colors.white);
    final double fillAlpha = glass
        ? (1.0 - np.miniTransparency).clamp(0.05, 0.85)
        : 0.90; // 降级：按主题深浅的半透明底保证可读（去"黑板"感）

    final Widget content = Container(
      height: 58,
      padding: const EdgeInsets.fromLTRB(7, 7, 6, 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(29),
        color: tint.withValues(alpha: fillAlpha),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08 + fillAlpha * 0.10),
          width: 0.8,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08 + fillAlpha * 0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );

    if (!glass) return content;
    return ClipRRect(
      borderRadius: BorderRadius.circular(29),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: content,
      ),
    );
  }
}
