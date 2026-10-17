/// 时长格式化扩展。
library;

extension DurationX on Duration {
  /// mm:ss（超过 1 小时自动切换 h:mm:ss）
  String get clock {
    final int totalSeconds = inSeconds;
    final int h = totalSeconds ~/ 3600;
    final int m = (totalSeconds % 3600) ~/ 60;
    final int s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 双位分钟格式，适合与 [clock] 配对展示
  String get mmss => clock;
}
