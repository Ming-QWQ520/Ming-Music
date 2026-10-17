/// 歌词视图（逐字优先 / 逐行回退）：
///
/// 交互（对齐 Zephyr-Music / 用户需求）：
///  - 单击歌词区域 → 切换封面/歌词视图（onToggleView 回调，双击等待延迟内触发）；
///  - 双击某行歌词 → seek 到该行起始时间；
///  - 进入歌词页首次定位使用 jumpTo 直接显示当前行（无滑动动画，固定行为
///    不再作为设置项）；切歌跟随滚动仍为平滑动画；
///  - 副行：有翻译显示翻译，无翻译显示音译拼音（romalrc，仿网易云）。
///
/// 自定义（NpPlayerSettings）：
///  - 字号 / 行距 / 对齐 / 副行 / 非活跃淡出与模糊 / 逐字着色。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/lyrics.dart';
import '../../../../core/utils/yrc_lyrics.dart';
import '../../domain/np_settings.dart';
import '../../providers/lyrics_providers.dart';
import '../../providers/player_providers.dart';
import '../../providers/np_settings_providers.dart';

class KaraokeLyricsView extends ConsumerStatefulWidget {
  const KaraokeLyricsView({
    super.key,
    this.lineExtent,
    this.onToggleView,
  });

  /// 统一行高（元数据行与歌词行同高，保证 animateTo 偏移精确）
  final double? lineExtent;

  /// 单击歌词区域 → 切换封面/歌词视图（null 时单击无动作）
  final VoidCallback? onToggleView;

  @override
  ConsumerState<KaraokeLyricsView> createState() => _KaraokeLyricsViewState();
}

class _KaraokeLyricsViewState extends ConsumerState<KaraokeLyricsView> {
  final ScrollController _scroll = ScrollController();
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastActive = -2;

  /// 首次定位是否已完成（directShow 用 jumpTo，之后切歌用 animateTo）
  bool _initialJumpDone = false;

  double get _extent => widget.lineExtent ?? AppConstants.yrcLineExtent;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int active) {
    // 无有效行（前奏/position 未就绪）不消费「首次定位」机会，
    // 保证 jumpTo 落在真正出现当前行的第一刻
    if (active < 0) return;
    if (active == _lastActive) return;
    final bool firstTime = !_initialJumpDone;
    _lastActive = active;
    _initialJumpDone = true;
    if (DateTime.now().isBefore(_suppressUntil)) return;
    if (!_scroll.hasClients) return;

    final double viewport = _scroll.position.viewportDimension;
    final double target = (active * _extent - viewport / 2 + _extent / 2)
        .clamp(0.0, _scroll.position.maxScrollExtent);

    // 首次定位：jumpTo 无动画（封面⇄歌词切换直接显示当前播放歌词，固定行为）
    if (firstTime) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: Duration(
          milliseconds:
              (340 * ref.read(npSettingsProvider).animationSpeed).round()),
      curve: Curves.easeOutCubic,
    );
  }

  void _onUserScroll() {
    _suppressUntil = DateTime.now().add(AppConstants.lyricScrollSuppression);
  }

  @override
  Widget build(BuildContext context) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final ParsedLyrics lyrics = ref.watch(currentLyricsProvider);

    final Widget body;
    if (lyrics.isEmpty) {
      body = Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 15,
          ),
        ),
      );
    } else {
      final Duration position =
          ref.watch(positionProvider).value ?? Duration.zero;

      if (lyrics.hasYrc) {
        final List<YrcLine> lines = lyrics.yrcLines;
        final int active = activeYrcIndex(lines, position);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _maybeAutoScroll(active);
        });
        body = ListView.builder(
          controller: _scroll,
          itemExtent: _extent,
          itemCount: lines.length,
          itemBuilder: (BuildContext context, int index) => _YrcRow(
            line: lines[index],
            position: position,
            active: index == active,
            cfg: cfg,
            subLine: lines[index].isMetadata
                ? ''
                : lyrics.subLineFor(lines[index].start.inMilliseconds),
            onSeek: _seek,
          ),
        );
      } else {
        final List<LyricLine> lines = lyrics.lrcLines;
        final int active = activeLyricIndex(lines, position);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _maybeAutoScroll(active);
        });
        body = ListView.builder(
          controller: _scroll,
          itemExtent: _extent,
          itemCount: lines.length,
          itemBuilder: (BuildContext context, int index) => _LrcRow(
            line: lines[index],
            // 副行：翻译优先，无翻译用音译拼音（仿网易云粤语歌）
            subLine: lyrics.subLineFor(lines[index].time.inMilliseconds),
            active: index == active,
            showSubLine: cfg.showTranslation,
            fontSize: cfg.lyricFontSize,
            align: cfg.lyricAlign,
            fade: cfg.lyricFade,
            onSeek: _seek,
          ),
        );
      }
    }

    // 单击歌词区域 → 切换封面/歌词视图；拖动滚动不触发（手势竞技场隔离）
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onToggleView,
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification n) {
          // 用户拖动即判定为手动滚动，抑制自动跟随
          final bool dragged =
              (n is ScrollStartNotification && n.dragDetails != null) ||
                  (n is ScrollUpdateNotification && n.dragDetails != null);
          if (dragged) {
            _onUserScroll();
          }
          return false;
        },
        child: body,
      ),
    );
  }

  void _seek(Duration time) {
    ref.read(playerProvider.notifier).seek(time);
  }
}

// ---------------------------------------------------------------- rows

/// 逐字行：行内每个字按已唱/未唱着色；双击 seek；可带音译/翻译副行
class _YrcRow extends StatelessWidget {
  const _YrcRow({
    required this.line,
    required this.position,
    required this.active,
    required this.cfg,
    required this.subLine,
    required this.onSeek,
  });

  final YrcLine line;
  final Duration position;
  final bool active;
  final NpPlayerSettings cfg;
  final String subLine;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final bool metadata = line.isMetadata;
    final NpLyricAlign align = cfg.lyricAlign;

    final Color baseColor =
        metadata ? Colors.white.withValues(alpha: 0.28) : cfg.yrcUnplayed;
    final Color sungColor =
        metadata ? Colors.white.withValues(alpha: 0.60) : cfg.yrcPlayed;
    final double fontSize = metadata ? 13.5 : cfg.lyricFontSize;

    final List<InlineSpan> spans = <InlineSpan>[];
    for (final YrcWord w in line.words) {
      final bool sung =
          position >= w.end || (active && w.progress(position) > 0);
      spans.add(
        TextSpan(
          text: w.text,
          style: TextStyle(
            color: sung ? sungColor : baseColor,
            fontSize: fontSize,
            fontWeight: active && !metadata ? FontWeight.w700 : FontWeight.w500,
            height: 1.25,
          ),
        ),
      );
    }

    final Widget rich = Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: metadata ? null : () => onSeek(line.start),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: align == NpLyricAlign.center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: <Widget>[
            Align(
              alignment: align == NpLyricAlign.center
                  ? Alignment.center
                  : Alignment.centerLeft,
              child: rich,
            ),
            if (subLine.isNotEmpty && cfg.showTranslation && active)
              Text(
                subLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 12.5,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 逐行行（LRC 回退）：当前行高亮 + 翻译/音译副行；双击 seek
class _LrcRow extends StatelessWidget {
  const _LrcRow({
    required this.line,
    required this.subLine,
    required this.active,
    required this.showSubLine,
    required this.fontSize,
    required this.align,
    required this.fade,
    required this.onSeek,
  });

  final LyricLine line;
  final String subLine;
  final bool active;
  final bool showSubLine;
  final double fontSize;
  final NpLyricAlign align;
  final double fade;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final CrossAxisAlignment cross = align == NpLyricAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => onSeek(line.time),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: cross,
          children: <Widget>[
            Text(
              line.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.05 + (1 - fade) * 0.40),
                fontSize: active ? fontSize : fontSize - 1.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            if (subLine.isNotEmpty && showSubLine)
              Text(
                subLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active
                      ? Colors.white.withValues(alpha: 0.72)
                      : Colors.white
                          .withValues(alpha: (1 - fade) * 0.26 + 0.02),
                  fontSize: 12.5,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
