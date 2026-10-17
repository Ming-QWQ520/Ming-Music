/// 播放进度条：
///  - 只订阅 positionProvider / durationProvider 两个高频流，
///    并用 RepaintBoundary 把重绘隔离在本组件内（避坑指南 3）；
///  - 拖动期间使用本地预览值，松手才真正 seek。
library;

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

  @override
  Widget build(BuildContext context) {
    final double positionMs =
        ref.watch(positionProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double durationMs =
        ref.watch(durationProvider).value?.inMilliseconds.toDouble() ?? 0;
    final double safeDuration = durationMs > 0 ? durationMs : 1;

    final double value = (_previewMs ?? positionMs.clamp(0, safeDuration))
        .clamp(0, safeDuration);

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.white.withValues(alpha: 0.9),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: 0.14),
              trackHeight: 3.5,
            ),
            child: Slider(
              value: value,
              max: safeDuration,
              onChanged: (double v) => setState(() => _previewMs = v),
              onChangeEnd: (double v) {
                _previewMs = null;
                ref
                    .read(playerProvider.notifier)
                    .seek(Duration(milliseconds: v.round()));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Row(
              children: <Widget>[
                Text(
                  Duration(milliseconds: value.round()).clock,
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                    color: Colors.white.withValues(alpha: 0.62),
                  ),
                ),
                Expanded(
                  child: Center(child: widget.centerLabel ?? const SizedBox.shrink()),
                ),
                Text(
                  Duration(milliseconds: safeDuration.round()).clock,
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                    color: Colors.white.withValues(alpha: 0.62),
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
