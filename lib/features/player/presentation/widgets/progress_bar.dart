/// 播放进度条（需求：Apple Music 样式 —— 自绘双层圆角条）：
///  - 无头部圆点；「当前进度条」与「总进度条」**完全等高等大**（同一
///    trackHeight，旧 M3 Slider 实现两条观感粗细不一致的问题根除）；
///  - 手动拖动时两条**以同一倍数平滑变粗**（4 → 8），松手回弹 ——
///    Apple Music 效果；
///  - 高潮点白点（第十四批需求修复「未显示」）：直径 = 当前条高，与
///    总进度条**同大小同时变化**（常态 4px / 拖动 8px 同步插值）；
///    两处根因：① Positioned 只给 left 未给 width → Center 被撑满
///    「剩余宽度」，白点中心漂移到剩余区中点（仅合唱点靠近轨道末端
///    时才恰好落位 =「有概率显示/位置不对」）；补 width: 34 后中心
///    恒为 chorusX；② 纯白点与白色进度条同色融合 → 对齐 Zephyr
///    PlayerBar 的黑色外发光（box-shadow 0 0 2px black.55 +
///    0 0 4px white.6），任何底色上均可辨；仅显示不拦截拖动；
///  - 自绘替代 SliderTheme：根治 M3 RoundedRectTrackShape 在无圆点
///    配置下 active/inactive 分段圆角与间隙的观感差异，并保证轨道
///    两侧内收与 m:s 时间标签对齐；
///  - 拖动期间使用本地预览值，松手才真正 seek；
///  - 只订阅 positionProvider / durationProvider，RepaintBoundary 隔离；
///  - 高潮点（副歌）白点仅显示不响应点击（保留长按气泡提示）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/duration_utils.dart';
import '../../providers/player_providers.dart';

class PlayerProgressBar extends ConsumerStatefulWidget {
  const PlayerProgressBar({super.key, this.compact = false, this.centerLabel});

  final bool compact;

  /// 进度行中央标签（仿网易云：音质标识）
  final Widget? centerLabel;

  @override
  ConsumerState<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends ConsumerState<PlayerProgressBar> {
  double? _previewMs;

  /// 是否正在拖动（Apple Music：拖动时两条一起变粗）
  bool _dragging = false;

  /// 当前曲目标识（切歌时复位预览态用）
  Object? _lastTrackKey;

  /// 常规/拖动态的条高（Apple Music 观感：4 → 8）
  static const double _kRestHeight = 4;
  static const double _kDragHeight = 8;

  /// 轨道两侧内收量：与时间标签行的水平 padding 一致，
  /// 需求「进度条不要超过 m:s 标签」
  static const double _kTrackInset = 16;

  void _seekToDx(double dx, double width) {
    final double safeWidth = math.max(1.0, width - _kTrackInset * 2);
    final double frac = ((dx - _kTrackInset) / safeWidth).clamp(0.0, 1.0);
    final double durationMs =
        ref.read(durationProvider).value?.inMilliseconds.toDouble() ?? 0;
    if (durationMs <= 0) return;
    setState(() {
      _previewMs = frac * durationMs;
      _dragging = true;
    });
  }

  /// 提交预览位置：真正 seek + 复位预览态
  ///（需求修复：拖动/点按后进度不跳转）
  void _commitPreview() {
    final double? v = _previewMs;
    setState(() {
      _dragging = false;
      _previewMs = null;
    });
    if (v != null) {
      ref.read(playerProvider.notifier).seek(Duration(milliseconds: v.round()));
    }
  }

  /// 复位预览态（手势被打断/取消时不 seek）
  ///（需求修复：加粗「hover」效果未取消复原）
  void _resetPreview() {
    if (_previewMs == null && !_dragging) return;
    setState(() {
      _dragging = false;
      _previewMs = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 需求修复（进度条 bug）：切歌瞬间复位预览态 —— 切歌时旧预览值
    // /加粗态若残留，显示与真实进度脱节且手势状态错乱（「刚切换歌曲时」
    // 复现的主路径；拖动中不受影响：仅复位非拖动残留）
    final Object? trackKey =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack?.id));
    if (trackKey != _lastTrackKey) {
      _lastTrackKey = trackKey;
      _previewMs = null;
      _dragging = false;
    }

    final double positionMs =
        ref.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double durationMs =
        ref.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double safeDuration = durationMs > 0 ? durationMs : 1;

    final double value = (_previewMs ?? positionMs.clamp(0, safeDuration))
        .clamp(0, safeDuration);

    // 高潮点（副歌起点，毫秒）：null = 无数据不显示白点
    final int? chorusMs =
        widget.compact ? null : ref.watch(currentChorusStartProvider);

    final Widget bar = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _dragging ? _kDragHeight : _kRestHeight),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (BuildContext ctx, double height, _) {
        // 自绘双层圆角条：当前进度条与总进度条同一高度同一圆角
        //（需求修复：旧 M3 Slider 两条粗细观感不一致）
        return SizedBox(
          height: math.max(height, _kDragHeight),
          child: Center(
            child: LayoutBuilder(
              builder: (BuildContext ctx, BoxConstraints cons) {
                final double w = cons.maxWidth;
                final double filled = (w - _kTrackInset * 2) *
                    (value / safeDuration).clamp(0.0, 1.0);
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    // 总进度条（底）：白 25%
                    Positioned(
                      left: _kTrackInset,
                      right: _kTrackInset,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Container(
                          height: height,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(height / 2),
                          ),
                        ),
                      ),
                    ),
                    // 当前进度条：白 90%，与总条同高同大
                    Positioned(
                      left: _kTrackInset,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Container(
                          width: math.max(filled, height),
                          height: height,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(height / 2),
                          ),
                        ),
                      ),
                    ),
                    // 高潮点白点（第十三批需求）：直径与当前条高一致
                    //（同大小同时变化：常态 4px / 拖动 8px 同步插值）。
                    // 椭圆形变根因：Positioned top+bottom 传入 tight
                    // 高度约束，Center→SizedBox(34x30)→白点 6x6 被压缩成
                    // 6×H（H=条高插值）→ 穿过进度条时可见椭圆；OverflowBox
                    // 解除约束后白点以条高为直径正圆绘制。
                    // 第十四批「未显示」修复：① 补 width: 34 —— 只给 left
                    // 时 Center 被撑满剩余宽度，白点中心=剩余区中点而非
                    // chorusX（仅靠近末尾时才恰好正确）；② 纯白点与白色
                    // 进度条同色 → 改用 Zephyr 同款黑色外发光暗环。
                    if (chorusMs != null &&
                        chorusMs > 0 &&
                        chorusMs < safeDuration)
                      Positioned(
                        width: 34,
                        left: (_kTrackInset +
                                (w - _kTrackInset * 2) *
                                    (chorusMs / safeDuration).clamp(0.0, 1.0) -
                                17)
                            .clamp(0.0, math.max(0.0, w - 34)),
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: OverflowBox(
                            alignment: Alignment.center,
                            maxWidth: double.infinity,
                            maxHeight: double.infinity,
                            child: Tooltip(
                              message:
                                  '高潮点 ${Duration(milliseconds: chorusMs).clock}',
                              triggerMode: TooltipTriggerMode.longPress,
                              preferBelow: false,
                              verticalOffset: 24,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              textStyle: const TextStyle(
                                  fontSize: 11.5, color: Colors.white),
                              // 命中区固定 34x34（不随条高压缩），
                              // 白点本体直径 = 条高 height
                              child: SizedBox(
                                width: 34,
                                height: 34,
                                child: Center(
                                  // Zephyr PlayerBar .chorus-dot 同款观感：
                                  // 白色圆点 + 黑色外发光暗环（0 0 2px
                                  // black55）+ 白色微光晕（0 0 4px white60），
                                  // 在白 25% 轨道与白 90% 已播条上都可辨
                                  child: Container(
                                    width: height,
                                    height: height,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white,
                                      boxShadow: <BoxShadow>[
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.55),
                                          blurRadius: 2,
                                        ),
                                        BoxShadow(
                                          color: Colors.white
                                              .withValues(alpha: 0.60),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 手势层：点按/拖动均可定位（拖动期间两条同步放大）
          // 需求修复（进度条 bug）：旧实现只注册 onTapDown/onHorizontalDrag*，
          // 点按松手无回调提交 → _previewMs/_dragging 永久滞留：显示冻结
          // 在点按处、加粗态不回弹；手势被取消（切歌打断竞技场）也无复位。
          // 补齐 onTapUp 提交 + onTapCancel/onHorizontalDragCancel 复位
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails d) {
              final RenderBox? box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _seekToDx(box.globalToLocal(d.globalPosition).dx, box.size.width);
            },
            onTapUp: (TapUpDetails d) {
              final RenderBox? box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _seekToDx(box.globalToLocal(d.globalPosition).dx, box.size.width);
              _commitPreview();
            },
            onTapCancel: _resetPreview,
            onHorizontalDragStart: (DragStartDetails d) {
              final RenderBox? box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _seekToDx(box.globalToLocal(d.globalPosition).dx, box.size.width);
            },
            onHorizontalDragUpdate: (DragUpdateDetails d) {
              final RenderBox? box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _seekToDx(box.globalToLocal(d.globalPosition).dx, box.size.width);
            },
            onHorizontalDragEnd: (DragEndDetails d) => _commitPreview(),
            onHorizontalDragCancel: _resetPreview,
            child: bar,
          ),
          Padding(
            // 与轨道内收量一致：时间文本与轨道端点齐平。
            // 第十三批需求（音质按键抖动修复）：左右时间套固定宽度，
            // 分/时位数变化（1:23 → 10:23）不再推移中央标签位置。
            padding: const EdgeInsets.only(
                left: _kTrackInset, right: _kTrackInset, top: 2),
            child: Row(
              children: <Widget>[
                // 当前播放进度文字：拖动时轻微高亮（需求）—— 白色加重 +
                // 轻微白光晕，AnimatedDefaultTextStyle 平滑过渡；
                // 只高亮当前进度（左侧），总时长保持原样式
                SizedBox(
                  width: 44,
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    style: TextStyle(
                      fontSize: 12,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures()
                      ],
                      color: _dragging
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.62),
                      fontWeight: _dragging ? FontWeight.w700 : FontWeight.w400,
                      shadows: _dragging
                          ? <Shadow>[
                              Shadow(
                                color: Colors.white.withValues(alpha: 0.45),
                                blurRadius: 6,
                              ),
                            ]
                          : const <Shadow>[],
                    ),
                    child: Text(Duration(milliseconds: value.round()).clock),
                  ),
                ),
                Expanded(
                  child: Center(
                      child: widget.centerLabel ?? const SizedBox.shrink()),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    Duration(milliseconds: safeDuration.round()).clock,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 12,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures()
                      ],
                      color: Colors.white.withValues(alpha: 0.62),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
