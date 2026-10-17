/// 歌词视图（逐字优先 / 逐行回退）：
///
/// 逐字擦除动画对齐 Zephyr-Music（NpLyrics.vue 的 yrc-wipe）：
///  - rAF 等价物 Ticker 逐帧直读播放内核 position（不经 200ms 节流流）；
///  - 每个「字/词单元」独立进度 0..1，按字符宽度水平裁剪已唱色层，
///    与 CSS `linear-gradient + background-clip:text` 的整体擦除观感一致；
///  - 未唱灰 / 已唱白双色，活动行加粗；
///
/// 排版（对应需求）：
///  - 歌词按屏幕宽度自适应换行（SoftWrap，高度按 TextPainter 预测量缓存，
///    滚动定位用累计高度精确居中）；
///  - 行间隔在设置值基础上整体 -4px；
///  - 副行：有翻译显示翻译，无翻译显示音译拼音；所有行都显示（仿网易云，
///    非活动行更淡）；
///
/// 交互（对齐 Zephyr-Music / 用户需求）：
///  - 单击歌词区域 → 切换封面/歌词视图（onToggleView）；
///  - 双击某行歌词 → seek 到该行起始时间；
///  - 进入歌词页首次定位 jumpTo 直显当前行（固定行为），切歌平滑跟随。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer;

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/lyrics.dart';
import '../../../../core/utils/yrc_lyrics.dart';
import '../../domain/np_settings.dart';
import '../../providers/lyrics_providers.dart';
import '../../providers/player_providers.dart';
import '../../providers/np_settings_providers.dart';

/// 行间隔（设置值整体 -4px，上下各一半，最低 2px）
double _gapV(NpPlayerSettings cfg) {
  final double v = (cfg.lyricLineGap - 4) / 2;
  return v < 2 ? 2 : v;
}

/// 文本测量缓存（key → 高度）：跨行共享，避免每帧/每行重复 layout。
/// 歌词切换/字体变化时 key 天然失效，容量超限整体清空。
final Map<String, double> _kTextHeightCache = <String, double>{};

double _measureTextHeight(
  String text,
  TextStyle style,
  double maxWidth,
  TextAlign align, {
  int maxLines = 8,
}) {
  if (text.isEmpty) return 0;
  final String key = '${text.hashCode}|${style.fontSize}|'
      '${style.fontWeight?.value}|${maxWidth.toStringAsFixed(1)}|'
      '${style.height}|$maxLines';
  final double? cached = _kTextHeightCache[key];
  if (cached != null) return cached;
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  final double h = tp.height;
  tp.dispose();
  if (_kTextHeightCache.length > 1024) _kTextHeightCache.clear();
  _kTextHeightCache[key] = h;
  return h;
}

class KaraokeLyricsView extends ConsumerStatefulWidget {
  const KaraokeLyricsView({super.key, this.onToggleView});

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

  // 高度缓存 key（内容/排版任一变化即失效）
  Object? _heightsKey;
  List<double>? _heights;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int active, List<double> heights) {
    // 无有效行（前奏/position 未就绪）不消费「首次定位」机会，
    // 保证 jumpTo 落在真正出现当前行的第一刻
    if (active < 0 || active >= heights.length) return;
    if (active == _lastActive) return;
    final bool firstTime = !_initialJumpDone;
    _lastActive = active;
    _initialJumpDone = true;
    if (DateTime.now().isBefore(_suppressUntil)) return;
    if (!_scroll.hasClients) return;

    final double viewport = _scroll.position.viewportDimension;
    final double top = heights.sublist(0, active).fold<double>(0, (double a, double h) => a + h);
    final double target =
        (top - viewport / 2 + heights[active] / 2).clamp(0.0, _scroll.position.maxScrollExtent);

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

      body = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final double innerWidth = width - 56; // 行内左右 padding 28

          // 行高缓存（内容/字号/行距/翻译开关/宽度任一变化即重算）
          final Object key = Object.hash(
            identityHashCode(lyrics),
            cfg.lyricFontSize,
            cfg.lyricLineGap,
            cfg.lyricAlign,
            cfg.showTranslation,
            innerWidth.toStringAsFixed(1),
          );
          if (_heights == null || _heightsKey != key) {
            _heightsKey = key;
            _heights = _measureAll(lyrics, cfg, innerWidth);
          }
          final List<double> heights = _heights!;

          if (lyrics.hasYrc) {
            final List<YrcLine> lines = lyrics.yrcLines;
            final int active = activeYrcIndex(lines, position);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _maybeAutoScroll(active, heights);
            });
            return ListView.builder(
              controller: _scroll,
              itemCount: lines.length,
              itemBuilder: (BuildContext context, int index) {
                final YrcLine line = lines[index];
                return _YrcRow(
                  line: line,
                  position: position,
                  active: index == active,
                  cfg: cfg,
                  width: innerWidth,
                  subLine: line.isMetadata
                      ? ''
                      : lyrics.subLineFor(line.start.inMilliseconds),
                  onSeek: _seek,
                );
              },
            );
          }

          final List<LyricLine> lines = lyrics.lrcLines;
          final int active = activeLyricIndex(lines, position);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _maybeAutoScroll(active, heights);
          });
          return ListView.builder(
            controller: _scroll,
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
              gapV: _gapV(cfg),
              onSeek: _seek,
            ),
          );
        },
      );
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

  /// 预测量所有行高（与行组件同一套样式参数，保证滚动偏移精确）
  List<double> _measureAll(ParsedLyrics lyrics, NpPlayerSettings cfg, double width) {
    final TextAlign align =
        cfg.lyricAlign == NpLyricAlign.center ? TextAlign.center : TextAlign.left;
    // 行间隔：设置值整体 -4px（需求）
    final double gapV = _gapV(cfg);

    double subHeight(String sub) {
      if (sub.isEmpty || !cfg.showTranslation) return 0;
      return _measureTextHeight(
        sub,
        TextStyle(fontSize: 12.5, height: 1.3),
        width,
        align,
        maxLines: 2,
      );
    }

    if (lyrics.hasYrc) {
      return <double>[
        for (final YrcLine line in lyrics.yrcLines)
          () {
            final bool metadata = line.isMetadata;
            final TextStyle style = TextStyle(
              fontSize: metadata ? 13.5 : cfg.lyricFontSize,
              fontWeight: metadata ? FontWeight.w500 : FontWeight.w700,
              height: 1.35,
            );
            double h =
                _measureTextHeight(line.text, style, width, align) + gapV * 2;
            if (!metadata) h += subHeight(lyrics.subLineFor(line.start.inMilliseconds));
            return h;
          }(),
      ];
    }
    return <double>[
      for (final LyricLine line in lyrics.lrcLines)
        () {
          final TextStyle style = TextStyle(
            fontSize: cfg.lyricFontSize,
            fontWeight: FontWeight.w600,
            height: 1.35,
          );
          double h =
              _measureTextHeight(line.text, style, width, align) + gapV * 2;
          h += subHeight(lyrics.subLineFor(line.time.inMilliseconds));
          return h;
        }(),
    ];
  }

  void _seek(Duration time) {
    ref.read(playerProvider.notifier).seek(time);
  }
}

/// 行内水平 padding（左右各 28）
const double _kRowHPadding = 28;

// ---------------------------------------------------------------- 逐字行

/// 逐字行：活动行 Ticker + CustomPainter 逐词擦除；非活动行静态双色；
/// 自适应换行；双击 seek；副行（翻译/音译）
class _YrcRow extends ConsumerStatefulWidget {
  const _YrcRow({
    required this.line,
    required this.position,
    required this.active,
    required this.cfg,
    required this.width,
    required this.subLine,
    required this.onSeek,
  });

  final YrcLine line;
  final Duration position;
  final bool active;
  final NpPlayerSettings cfg;
  final double width;
  final String subLine;
  final ValueChanged<Duration> onSeek;

  @override
  ConsumerState<_YrcRow> createState() => _YrcRowState();
}

class _YrcRowState extends ConsumerState<_YrcRow>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  final _WipeTick _tick = _WipeTick();
  Duration _lastPos = Duration.zero;
  bool _lastPlaying = false;

  @override
  void initState() {
    super.initState();
    if (widget.active && !widget.line.isMetadata) {
      _startTicker();
    }
  }

  @override
  void didUpdateWidget(_YrcRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool needTicker = widget.active && !widget.line.isMetadata;
    if (needTicker && _ticker == null) _startTicker();
    if (!needTicker && _ticker != null) _stopTicker();
  }

  void _startTicker() {
    _ticker = createTicker((Duration elapsed) {
      final AudioPlayer player = ref.read(audioHandlerProvider).player;
      final Duration pos = player.position;
      final bool playing = player.playing;
      // 仅在播放推进或状态切换时触发重绘（暂停静止省电）
      if (playing != _lastPlaying || pos != _lastPos) {
        _lastPos = pos;
        _lastPlaying = playing;
        _tick.notify();
      }
    });
    _ticker!.start();
  }

  void _stopTicker() {
    _ticker?.dispose();
    _ticker = null;
    _tick.reset();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _tick.dispose();
    super.dispose();
  }

  Duration _positionOf() => ref.read(audioHandlerProvider).player.position;

  @override
  Widget build(BuildContext context) {
    final YrcLine line = widget.line;
    final NpPlayerSettings cfg = widget.cfg;
    final bool metadata = line.isMetadata;
    final NpLyricAlign align = cfg.lyricAlign;

    final Color baseColor =
        metadata ? Colors.white.withValues(alpha: 0.28) : cfg.yrcUnplayed;
    final Color sungColor =
        metadata ? Colors.white.withValues(alpha: 0.60) : cfg.yrcPlayed;
    final double fontSize = metadata ? 13.5 : cfg.lyricFontSize;
    final TextStyle style = TextStyle(
      fontSize: fontSize,
      fontWeight: metadata ? FontWeight.w500 : FontWeight.w700,
      height: 1.35,
    );
    final TextAlign textAlign =
        align == NpLyricAlign.center ? TextAlign.center : TextAlign.left;
    // 行间隔：与测量一致（设置值 -4px）
    final double gapV = _gapV(cfg);

    final String sub = metadata ? '' : widget.subLine;
    final bool showSub = sub.isNotEmpty && cfg.showTranslation;

    final Widget mainText;
    if (widget.active && !metadata && line.words.isNotEmpty) {
      // 活动行：Ticker 驱动的逐词擦除（对齐 Zephyr yrc-wipe）
      mainText = CustomPaint(
        size: Size(widget.width, _measureTextHeight(line.text, style, widget.width, textAlign)),
        painter: _WipePainter(
          text: line.text,
          style: style,
          words: line.words,
          playedColor: sungColor,
          unplayedColor: baseColor,
          textAlign: textAlign,
          positionOf: _positionOf,
          repaint: _tick,
        ),
      );
    } else {
      // 非活动行 / 元数据行：按 position 快照静态着色
      final List<InlineSpan> spans = <InlineSpan>[];
      for (final YrcWord w in line.words) {
        final bool sung = widget.position >= w.end;
        spans.add(TextSpan(
          text: w.text,
          style: style.copyWith(color: sung ? sungColor : baseColor),
        ));
      }
      if (spans.isEmpty) spans.add(TextSpan(text: ' ', style: style));
      mainText = Text.rich(
        TextSpan(children: spans),
        textAlign: textAlign,
      );
    }

    final CrossAxisAlignment cross = align == NpLyricAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: metadata ? null : () => widget.onSeek(line.start),
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: _kRowHPadding, vertical: gapV),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: cross,
          children: <Widget>[
            Align(
              alignment: align == NpLyricAlign.center
                  ? Alignment.center
                  : Alignment.centerLeft,
              child: mainText,
            ),
            if (showSub)
              Text(
                sub,
                textAlign: textAlign,
                style: TextStyle(
                  color: widget.active
                      ? Colors.white.withValues(alpha: 0.72)
                      : Colors.white.withValues(alpha: 0.45),
                  fontSize: 12.5,
                  height: 1.3,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 擦除重绘信号：Ticker 每 tick notify，CustomPainter 以此为 repaint 源
class _WipeTick extends ChangeNotifier {
  void notify() => notifyListeners();
  void reset() => notifyListeners();
}

/// 逐词擦除画笔：底层整行未唱色，上层已唱色按每词进度水平裁剪。
/// 与 Zephyr 的 CSS 渐变擦除等价：词内所有字符共享同一进度、整体扫过。
class _WipePainter extends CustomPainter {
  _WipePainter({
    required this.text,
    required this.style,
    required this.words,
    required this.playedColor,
    required this.unplayedColor,
    required this.textAlign,
    required this.positionOf,
    required ChangeNotifier repaint,
  }) : super(repaint: repaint);

  final String text;
  final TextStyle style;
  final List<YrcWord> words;
  final Color playedColor;
  final Color unplayedColor;
  final TextAlign textAlign;
  final Duration Function() positionOf;

  TextPainter? _dim;
  TextPainter? _bright;
  double? _laidWidth;
  List<List<Rect>>? _wordBoxes;

  void _ensure(double width) {
    if (_dim != null && _laidWidth == width) return;
    _dim?.dispose();
    _bright?.dispose();
    _dim = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(color: unplayedColor)),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
    )..layout(maxWidth: width);
    _bright = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(color: playedColor)),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
    )..layout(maxWidth: width);
    _laidWidth = width;

    // 每词字形盒（UTF-16 code unit 语义与 String.length 一致）
    final List<List<Rect>> boxes = <List<Rect>>[];
    int offset = 0;
    for (final YrcWord w in words) {
      final int start = offset;
      final int end = offset + w.text.length;
      offset = end;
      final List<TextBox> raw = _bright!.getBoxesForSelection(
        TextSelection(
            baseOffset: start.clamp(0, text.length),
            extentOffset: end.clamp(0, text.length)),
        boxHeightStyle: ui.BoxHeightStyle.tight,
      );
      boxes.add(raw
          .map((TextBox b) => Rect.fromLTRB(b.left, b.top, b.right, b.bottom))
          .toList(growable: false));
    }
    _wordBoxes = boxes;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final TextPainter? dim = _dim;
    final TextPainter? bright = _bright;
    if (dim == null || bright == null) return;
    _ensure(size.width);

    dim.paint(canvas, Offset.zero);

    final Duration t = positionOf();
    final List<List<Rect>>? boxes = _wordBoxes;
    if (boxes == null) return;

    for (int i = 0; i < words.length && i < boxes.length; i++) {
      final YrcWord w = words[i];
      final double prog = w.progress(t);
      if (prog <= 0) continue;
      final double frac = prog.clamp(0.0, 1.0);
      for (final Rect box in boxes[i]) {
        final double cut = box.width * frac;
        if (cut <= 0) continue;
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(
          box.left, box.top, box.left + cut, box.bottom,
        ));
        bright.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_WipePainter oldDelegate) => true;
}

// ---------------------------------------------------------------- 逐行行

/// 逐行行（LRC 回退）：当前行高亮 + 翻译/音译副行（所有行显示）；双击 seek
class _LrcRow extends StatelessWidget {
  const _LrcRow({
    required this.line,
    required this.subLine,
    required this.active,
    required this.showSubLine,
    required this.fontSize,
    required this.align,
    required this.fade,
    required this.gapV,
    required this.onSeek,
  });

  final LyricLine line;
  final String subLine;
  final bool active;
  final bool showSubLine;
  final double fontSize;
  final NpLyricAlign align;
  final double fade;
  final double gapV;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final TextAlign textAlign =
        align == NpLyricAlign.center ? TextAlign.center : TextAlign.left;
    final CrossAxisAlignment cross = align == NpLyricAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final String sub = showSubLine ? subLine : '';
    final bool showSub = sub.isNotEmpty;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => onSeek(line.time),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _kRowHPadding, vertical: gapV),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: cross,
          children: <Widget>[
            Text(
              line.text,
              textAlign: textAlign,
              softWrap: true,
              style: TextStyle(
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.05 + (1 - fade) * 0.40),
                fontSize: fontSize,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                height: 1.35,
              ),
            ),
            if (showSub)
              Text(
                sub,
                textAlign: textAlign,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active
                      ? Colors.white.withValues(alpha: 0.72)
                      : Colors.white.withValues(alpha: 0.45),
                  fontSize: 12.5,
                  height: 1.3,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
