/// 单行跑马灯文本：溢出时平滑向右滚动，滚至尽头停留 3s 后重新滚动。
///
/// 行为（需求：歌曲名称过长则平滑向右滚动，滚动至尽头时停留 3s 后重新滚动）：
///  - 文本未溢出：静态显示；
///  - 溢出：向左平移至文本尽头 → 停留 [endPause] → 瞬间回到起点再滚动，
///    循环往复；滚动时长与溢出宽度成正比（约 40ms/px，不低于 1.6s）。
///
/// 参考 kgka_Music_hl `_MarqueeSingleLine` 的溢出测量思路，
/// 停留与重滚节奏对齐网易云播放页。
library;

import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.overflowIndent = 24,
    this.velocity = 40,
    this.endPause = const Duration(seconds: 3),
    this.textAlign = TextAlign.start,
  });

  final String text;
  final TextStyle? style;
  final int maxLines;

  /// 尾部渐隐遮罩宽度（右侧淡出，避免文字生硬截断）
  final double overflowIndent;

  /// 滚动速度（px/s）
  final double velocity;

  /// 滚到尽头后的停留时长
  final Duration endPause;

  /// 文本对齐（未溢出时生效；溢出滚动时恒为左滚）
  final TextAlign textAlign;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this);

  /// 溢出宽度（>0 才滚动）
  double _overflow = 0;

  Duration _scrollDuration(double overflow) {
    final double ms = (overflow / widget.velocity) * 1000;
    return Duration(milliseconds: ms.clamp(1600.0, 12000.0).round());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _measure();
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _overflow = 0;
      _measure();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 文本排版测量溢出宽度，配置控制器时长
  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      final double width = box?.size.width ?? 0;
      if (width <= 0) return;

      final TextPainter painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: TextDirection.ltr,
        maxLines: widget.maxLines,
      )..layout(maxWidth: double.infinity);
      final double textWidth = painter.width;
      painter.dispose();

      final double overflow = (textWidth - width).clamp(0.0, double.infinity);
      if ((overflow - _overflow).abs() < 0.5) return;
      setState(() => _overflow = overflow);

      if (overflow > 0) {
        final Duration scroll = _scrollDuration(overflow);
        // 总时长 = 滚动 + 尽头停留；滚动段占前 scroll/total 比例
        _ctrl.duration = scroll + widget.endPause;
        if (!_ctrl.isAnimating) _ctrl.repeat();
      } else {
        _ctrl.stop();
        _ctrl.value = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style =
        (widget.style ?? DefaultTextStyle.of(context).style);
    final bool scrollable = _overflow > 0;

    final Widget content = Text(
      widget.text,
      maxLines: widget.maxLines,
      textAlign: widget.textAlign,
      overflow: scrollable ? TextOverflow.visible : TextOverflow.ellipsis,
      softWrap: false,
      style: style,
    );

    if (!scrollable) return content;

    return ClipRect(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (BuildContext ctx, Widget? child) {
          final Duration total = _ctrl.duration ?? const Duration(seconds: 4);
          final double scrollFraction =
              (scroll(total).inMilliseconds / total.inMilliseconds)
                  .clamp(0.01, 1.0);
          final double t = _ctrl.value;
          // 滚动段：0→1 线性；停留段：恒为 1（停在尽头）
          final double p = (t / scrollFraction).clamp(0.0, 1.0);
          return Transform.translate(
            offset: Offset(-_overflow * p, 0),
            child: child,
          );
        },
        child: content,
      ),
    );
  }

  Duration scroll(Duration total) => total - widget.endPause;
}
