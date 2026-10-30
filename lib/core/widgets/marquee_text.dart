/// 单行跑马灯文本（需求：往返滚动）——
///
/// 行为（需求：滚动至最右侧停留 3s 后向左滚动回起点，停留 3s 后
/// 再向右滚动，一直重复）：
///  - 文本未溢出：静态显示；
///  - 溢出：向左平移至文本尽头（露出结尾）→ 停留 [endPause] →
///    平滑滚回起点 → 再停留 [endPause] → 循环往复（乒乓式，
///    不再旧版的「瞬间回跳」）；滚动时长与溢出宽度成正比
///    （约 40ms/px，不低于 1.6s）。
///
/// 参考 kgka_Music_hl `_MarqueeSingleLine` 的溢出测量思路。
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

  /// 滚到尽头/起点后的停留时长
  final Duration endPause;

  /// 文本对齐（未溢出时生效；溢出滚动时恒为左对齐往返）
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
        // 乒乓总时长 = 去 + 停 + 回 + 停；滚动段占每半程
        // scroll/total 比例（去程 0→s，回程 2s→3s）
        final Duration half = _scrollDuration(overflow) + widget.endPause;
        _ctrl.duration = half * 2;
        if (!_ctrl.isAnimating) _ctrl.repeat();
      } else {
        _ctrl.stop();
        _ctrl.value = 0;
      }
    });
  }

  /// 乒乓位移分数：0 = 起点，1 = 尽头。
  /// 半程占比 s = scroll/total：
  ///  [0, s)      0→1 向尽头滚；
  ///  [s, 2s)     1   尽头停留；
  ///  [2s, 3s)    1→0 滚回起点；
  ///  [3s, 4s)    0   起点停留（repeat 后循环）。
  double _pong(double t, double s) {
    if (t < s) return t / s;
    if (t < 2 * s) return 1;
    if (t < 3 * s) return 1 - (t - 2 * s) / s;
    return 0;
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
          final Duration total = _ctrl.duration ?? const Duration(seconds: 8);
          final double scrollFraction =
              (scroll(total).inMilliseconds / total.inMilliseconds)
                  .clamp(0.01, 0.49);
          final double p = _pong(_ctrl.value, scrollFraction);
          return Transform.translate(
            offset: Offset(-_overflow * p, 0),
            child: child,
          );
        },
        child: content,
      ),
    );
  }

  /// 单程滚动时长（总时长 - 两个停留段）
  Duration scroll(Duration total) => total - widget.endPause * 2;
}
