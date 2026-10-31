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

import 'dart:math' as math;
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
  const KaraokeLyricsView({super.key, this.onToggleView, this.bottomInset = 0});

  /// 单击歌词区域 → 切换封面/歌词视图（null 时单击无动作）
  final VoidCallback? onToggleView;

  /// 底部被信息区/控制栏覆盖的高度：自动滚动定位在「可视区中部」
  /// （需求：歌名整块区域透明可见歌词 —— 歌词延伸到信息区背后）
  final double bottomInset;

  @override
  ConsumerState<KaraokeLyricsView> createState() => _KaraokeLyricsViewState();
}

class _KaraokeLyricsViewState extends ConsumerState<KaraokeLyricsView> {
  final ScrollController _scroll = ScrollController();
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastActive = -2;

  /// 边缘扩散淡出的滚动偏移快照：滚动偏移变化超过阈值时触发重建，
  /// 重算各行距上下边界的接近度（第十五批需求）
  double _lastEdgeOffset = -1;

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

    // 需求（歌名区透明可见歌词）：自动滚动以「可视区」为中心 ——
    // 底部被信息区/控制栏覆盖的部分不参与居中计算
    final double viewport = _scroll.position.viewportDimension;
    final double effVp =
        (viewport - widget.bottomInset).clamp(viewport * 0.35, viewport);
    final double top = heights
        .sublist(0, active)
        .fold<double>(0, (double a, double h) => a + h);
    final double target =
        (_edgeTopPadding + top - effVp / 2 + heights[active] / 2)
            .clamp(0.0, _scroll.position.maxScrollExtent);

    // 首次定位：jumpTo 无动画（封面⇄歌词切换直接显示当前播放歌词，固定行为）
    if (firstTime) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  /// 「时刻保持居中」模式的边缘填充量（build 内按可视区计算后暂存）
  double _edgeTopPadding = 0;

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

          // 行高缓存（内容/字号/行距/翻译开关/宽度/居中模式/底部避让任一变化即重算）
          final Object key = Object.hash(
            identityHashCode(lyrics),
            cfg.lyricFontSize,
            cfg.lyricLineGap,
            cfg.lyricAlign,
            cfg.showTranslation,
            cfg.lyricAlwaysCenter,
            widget.bottomInset.round(),
            innerWidth.toStringAsFixed(1),
          );
          if (_heights == null || _heightsKey != key) {
            _heightsKey = key;
            _heights = _measureAll(lyrics, cfg, innerWidth);
          }
          final List<double> heights = _heights!;

          // 需求「时刻保持居中」：并非锁定拖动，而是让当前行始终位于可视区
          // 中部 —— 开头/结尾行不贴边。实现：给内容加首尾边缘填充，使第一行
          // /最后一行也能滚动到可视区中心；拖动仍自由，松手后恢复跟随。
          // 可视区 = 列表高度 - 底部覆盖（歌名/控制区透明背景下歌词从其后穿过）。
          final double viewportH = constraints.maxHeight;
          final double effVp = (viewportH - widget.bottomInset)
              .clamp(viewportH * 0.35, viewportH);
          EdgeInsets listPadding;
          if (cfg.lyricAlwaysCenter && heights.isNotEmpty) {
            final double pTop =
                (effVp / 2 - heights.first / 2).clamp(0.0, double.infinity);
            // 底部填充使最后一行也可居中：vp+inset)/2 - hLast/2
            final double pBottom =
                ((viewportH + widget.bottomInset) / 2 - heights.last / 2)
                    .clamp(0.0, double.infinity);
            _edgeTopPadding = pTop;
            listPadding = EdgeInsets.only(top: pTop, bottom: pBottom);
          } else {
            _edgeTopPadding = 0;
            // 非居中模式：仅需保证尾部内容不被底部覆盖区遮死
            listPadding = EdgeInsets.only(bottom: widget.bottomInset + 24);
          }

          // 第十五批需求：非活跃行淡出 = 以上下歌词边界为起点向当前
          // 播放行扩散的轻模糊感 —— 按行中心距视口边界的接近度算出
          // 每行 edgeT（0 = 清晰，1 = 贴边），传入行组件施加模糊/减淡。
          final double scrollOff = _scroll.hasClients ? _scroll.offset : 0;
          final double edgeZone = (viewportH * 0.34).clamp(90.0, 280.0);
          double edgeTOf(int index) {
            if (index < 0 || index >= heights.length) return 0;
            double top = listPadding.top;
            for (int i = 0; i < index; i++) {
              top += heights[i];
            }
            final double center = top + heights[index] / 2 - scrollOff;
            final double dist = math.min(
                math.max(center, 0.0), math.max(viewportH - center, 0.0));
            return (1 - dist / edgeZone).clamp(0.0, 1.0);
          }

          if (lyrics.hasYrc) {
            final List<YrcLine> lines = lyrics.yrcLines;
            final int active = activeYrcIndex(lines, position);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _maybeAutoScroll(active, heights);
            });
            return ListView.builder(
              controller: _scroll,
              padding: listPadding,
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
                  edgeT: index == active ? 0 : edgeTOf(index),
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
            padding: listPadding,
            itemCount: lines.length,
            itemBuilder: (BuildContext context, int index) => _LrcRow(
              line: lines[index],
              // 副行：翻译优先，无翻译用音译拼音（仿网易云粤语歌）
              subLine: lyrics.subLineFor(lines[index].time.inMilliseconds),
              active: index == active,
              // 需求：修复「高亮已播放歌词」在逐行模式下无效果 ——
              // 已唱行（时间已过且非当前行）以已唱色弱高亮
              played: cfg.highlightPlayed &&
                  index != active &&
                  lines[index].time <= position,
              showSubLine: cfg.showTranslation,
              fontSize: cfg.lyricFontSize,
              align: cfg.lyricAlign,
              fade: cfg.lyricFade,
              blur: cfg.lyricBlur,
              gapV: _gapV(cfg),
              edgeT: index == active ? 0 : edgeTOf(index),
              onSeek: _seek,
            ),
          );
        },
      );
    }

    // 单击歌词区域 → 切换封面/歌词视图；拖动滚动不触发（手势竞技场隔离）
    // 外层 ShaderMask：Zephyr NpLyrics 同款上下边缘遮罩
    //（mask-image: transparent 0% → #000 18% → #000 82% → transparent 100%）
    //—— 远端歌词在视口边缘自然消隐，替代旧版按行距辐射变暗的观感
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
          // 第十五批需求：淡出 = 边界向当前行扩散的模糊感 —— 滚动时
          // 各行距边界距离变化，偏移量超过阈值后重建重算边缘强度
          if ((n is ScrollUpdateNotification || n is ScrollEndNotification) &&
              _scroll.hasClients &&
              (_scroll.offset - _lastEdgeOffset).abs() > 2.5) {
            _lastEdgeOffset = _scroll.offset;
            setState(() {});
          }
          return false;
        },
        child: ShaderMask(
          // Zephyr NpLyrics .lyrics-viewport 同款边缘遮罩：
          // mask-image: linear-gradient(180deg, transparent 0%,
          //   #000 18%, #000 82%, transparent 100%)
          // dstIn = 按遮罩 alpha 保留内容：上下 18% 渐隐、中部全显
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0.0, 0.18, 0.82, 1.0],
            colors: <Color>[
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
          ).createShader(bounds),
          child: body,
        ),
      ),
    );
  }

  /// 预测量所有行高（与行组件同一套样式参数，保证滚动偏移精确）
  List<double> _measureAll(
      ParsedLyrics lyrics, NpPlayerSettings cfg, double width) {
    final TextAlign align = cfg.lyricAlign == NpLyricAlign.center
        ? TextAlign.center
        : TextAlign.left;
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
            if (!metadata) {
              h += subHeight(lyrics.subLineFor(line.start.inMilliseconds));
            }
            return h;
          }(),
      ];
    }
    return <double>[
      for (final LyricLine line in lyrics.lrcLines)
        () {
          final TextStyle style = TextStyle(
            fontSize: cfg.lyricFontSize,
            // 与 _LrcRow 渲染字重一致（统一 w700，见切行字号修复）
            fontWeight: FontWeight.w700,
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

/// 非活跃行效果（第十六批需求重定义「淡出」语义）：
///
///  - **淡出 = 套在非活跃行上的模糊效果，不再联动亮度**：滑杆控制
///    上下边界向当前行扩散的模糊强度（距边界越近越模糊，最高
///    sigma = 1.5px × fade，需求第二十批：模糊最高 1.5px），滑杆为
///    0 时无模糊；[edgeT] 为行中心距边界的接近度（0 = 清晰，
///    1 = 贴边），由列表层按滚动偏移实时计算；
///  - **非活跃行基线压暗恒定 0.45，不随滑杆变化** —— 修复「淡出设为 0
///    时歌词几乎同色同亮」：非活跃行永远比当前行暗，淡出只加模糊、
///    绝不变亮歌词；
///  - 模糊（lyricBlur）保留为统一额外模糊，默认 0 = 关闭；
///  - 当前播放行永不受影响（active 时直通）。
/// RepaintBoundary 隔离模糊层，避免滚动时全列表重绘。
/// 需求（第二十四批）：歌词切行平滑曲线 —— 活动行⇄非活跃行的
/// 淡出/模糊过渡改为 320ms easeOutCubic 动画（旧实现瞬时跳变，
/// 切行瞬间亮度/模糊阶梯式突变；现新行缓缓点亮、旧行缓缓淡出）。
///
/// 实现说明：TweenAnimationBuilder 以 `end = active ? 0 : 1` 驱动动画值
/// t；[edgeT]（滚动边界接近度）仍随滚动逐帧变化 —— 父组件重建时
/// TweenAnimationBuilder 以当前动画值重跑 builder（end 未变则不重启
/// 动画），滚动实时性与切换平滑性互不干扰。
Widget _applyInactiveEffect(
  Widget child, {
  required double fade,
  required double blur,
  required bool active,
  double edgeT = 0,
}) {
  return TweenAnimationBuilder<double>(
    tween: Tween<double>(end: active ? 0 : 1),
    duration: const Duration(milliseconds: 320),
    curve: Curves.easeOutCubic,
    child: child,
    builder: (BuildContext context, double t, Widget? cached) {
      final Widget content = cached ?? child;
      if (t <= 0.01) return content; // 活动行：全亮、无模糊
      final double fadeV = fade.clamp(0.0, 1.0);
      // 边界扩散模糊（淡出主体，滑杆唯一作用点）+ 统一额外模糊（设置项，
      // 默认 0）；需求：非活跃行模糊最高 1.5px，整体随动画值 t 渐入
      final double edgeSigma = edgeT.clamp(0.0, 1.0) * 1.5 * fadeV;
      final double sigma =
          ((blur.clamp(0.0, 1.5) + edgeSigma) * t).clamp(0.0, 1.5);
      Widget result = content;
      if (sigma > 0.02) {
        result = RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: ui.TileMode.decal,
            ),
            child: result,
          ),
        );
      }
      // 第十六批修复：非活跃行基线压暗恒定（不随淡出滑杆变化），
      // 越贴边越透的边缘衰减保留；透明度随动画值 t 渐入渐出
      const double baseAlpha = 0.40;
      final double edgeAlpha = 1 - edgeT.clamp(0.0, 1.0) * 0.25 * fadeV;
      final double alpha =
          (1 - (1 - baseAlpha * edgeAlpha) * t).clamp(0.0, 1.0);
      if (alpha < 0.999) {
        result = Opacity(opacity: alpha, child: result);
      }
      return result;
    },
  );
}

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
    required this.edgeT,
    required this.onSeek,
  });

  final YrcLine line;
  final Duration position;
  final bool active;
  final NpPlayerSettings cfg;
  final double width;
  final String subLine;

  /// 行中心距视口边界的接近度（0 清晰 → 1 贴边，边界扩散模糊用）
  final double edgeT;

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
        size: Size(widget.width,
            _measureTextHeight(line.text, style, widget.width, textAlign)),
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
      // 非活动行 / 元数据行：静态着色。
      // 需求（高亮机制改造）：默认「只高亮当前播放行/字」—— 已播放行
      // 不再显示已唱色（保持未唱色）；开启「高亮已播放歌词」后恢复
      // 经典卡拉OK的已唱高亮。
      final List<InlineSpan> spans = <InlineSpan>[];
      for (final YrcWord w in line.words) {
        final bool sung = widget.position >= w.end && cfg.highlightPlayed;
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

    Widget rowContent = Column(
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
    );

    // 第十五批需求：非活跃行淡出 = 边界向当前行扩散的轻模糊感
    rowContent = _applyInactiveEffect(
      rowContent,
      fade: cfg.lyricFade,
      blur: cfg.lyricBlur,
      active: widget.active,
      edgeT: widget.edgeT,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: metadata ? null : () => widget.onSeek(line.start),
      child: Padding(
        padding:
            EdgeInsets.symmetric(horizontal: _kRowHPadding, vertical: gapV),
        child: rowContent,
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
    if (size.width <= 0 || size.height <= 0) return;
    // ⚠️ _ensure 必须在判空前调用：首次绘制时 _dim/_bright 尚未创建，
    // 旧实现先判空再初始化导致首帧直接 return、后续帧也永远无初始化，
    // 活动行完全透明不可见（用户反馈「擦除动画未成功播放」根因）。
    _ensure(size.width);
    final TextPainter? dim = _dim;
    final TextPainter? bright = _bright;
    if (dim == null || bright == null) return;

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
          box.left,
          box.top,
          box.left + cut,
          box.bottom,
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

/// 逐行行（LRC 回退）：当前行高亮 + 已唱行弱高亮（需求修复）+ 翻译/音译副行；
/// 双击 seek。
///
/// 需求（第二十一批）：无逐字歌词的歌曲不强制使用逐字 —— 逐行（LRC）
/// 模式恢复纯行高亮：活动行白字加粗，非活动行淡出/模糊，不再做
/// 伪逐字擦除（逐字双色擦除仅用于真有 yrc 数据的歌曲，与 _YrcRow 一致）。
class _LrcRow extends ConsumerStatefulWidget {
  const _LrcRow({
    required this.line,
    required this.subLine,
    required this.active,
    this.played = false,
    required this.showSubLine,
    required this.fontSize,
    required this.align,
    required this.fade,
    required this.blur,
    required this.gapV,
    required this.edgeT,
    required this.onSeek,
  });

  final LyricLine line;
  final String subLine;
  final bool active;

  /// 需求（修复「高亮已播放歌词无实际效果」）：逐行模式下已唱行
  /// 以接近当前行的亮度弱高亮，与未唱灰行区分
  final bool played;
  final bool showSubLine;
  final double fontSize;
  final NpLyricAlign align;
  final double fade;

  /// 非活跃行模糊强度（px，0 = 关闭；第十四批起不再按行距递增）
  final double blur;

  /// 行中心距视口边界的接近度（0 清晰 → 1 贴边，边界扩散模糊用）
  final double edgeT;

  final double gapV;
  final ValueChanged<Duration> onSeek;

  @override
  ConsumerState<_LrcRow> createState() => _LrcRowState();
}

class _LrcRowState extends ConsumerState<_LrcRow> {
  @override
  Widget build(BuildContext context) {
    final TextAlign textAlign =
        widget.align == NpLyricAlign.center ? TextAlign.center : TextAlign.left;
    final CrossAxisAlignment cross = widget.align == NpLyricAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final String sub = widget.showSubLine ? widget.subLine : '';
    final bool showSub = sub.isNotEmpty;

    // 需求（修复「高亮已播放歌词无实际效果」）：透明度交给
    // _applyInactiveEffect 统一处理
    final Color mainColor = widget.active
        ? Colors.white
        : widget.played
            ? Colors.white.withValues(alpha: 0.85)
            : Colors.white;

    // 需求（第二十一批）：无逐字歌词不强制逐字 —— 活动行与其它行同用
    // 静态文本（此前活动行走伪逐字擦除，逐字颜色设置也误伤纯 LRC 歌曲）
    final Widget mainText = Text(
      widget.line.text,
      textAlign: textAlign,
      softWrap: true,
      style: TextStyle(
        color: mainColor,
        fontSize: widget.fontSize,
        // 需求修复「当前播放行切换至下一行时文字大小轻微变小」：
        // 旧实现非活跃未播行 w500、活动行 w700，切行瞬间字重跳变
        // 导致字形尺寸观感突变 —— 统一 w700（层次交给透明度/模糊）
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
    );

    Widget rowContent = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: cross,
      children: <Widget>[
        Align(
          alignment: widget.align == NpLyricAlign.center
              ? Alignment.center
              : Alignment.centerLeft,
          child: mainText,
        ),
        if (showSub)
          Text(
            sub,
            textAlign: textAlign,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              // 副行透明度同样交给 _applyInactiveEffect 统一处理
              color: widget.active || widget.played
                  ? Colors.white.withValues(alpha: 0.68)
                  : Colors.white.withValues(alpha: 0.62),
              fontSize: 12.5,
              height: 1.3,
            ),
          ),
      ],
    );

    // 第十五批需求：非活跃行淡出 = 边界向当前行扩散的轻模糊感
    // 需求（第二十四批）：恒定包裹（active 交给效果函数内部动画）——
    // 旧实现仅在 !active 时包裹，行变活跃瞬间效果层直接摘除产生跳变；
    // 现在「点亮/淡出」双向均走 320ms easeOutCubic 曲线
    rowContent = _applyInactiveEffect(
      rowContent,
      fade: widget.fade,
      blur: widget.blur,
      active: widget.active,
      edgeT: widget.edgeT,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => widget.onSeek(widget.line.time),
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: _kRowHPadding, vertical: widget.gapV),
        child: rowContent,
      ),
    );
  }
}
