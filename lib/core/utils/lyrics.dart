/// LRC 歌词解析与高亮定位。
///
/// 使用 Dart 3 Records（`({Duration time, String text})`）承载歌词行，
/// 高亮定位采用二分查找，复杂度 O(log n)，配合 positionStream 每 200ms
/// 刷新毫无压力。
library;

/// 单行歌词：时间戳 + 文本（Dart 3 Record）
typedef LyricLine = ({Duration time, String text});

/// 中文弯引号（U+2018/U+2019）→ ASCII 直引号（需求：歌词引号统一显示）
final RegExp _curlyQuoteExp = RegExp('[\u2018\u2019]');

final RegExp _tagExp = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// 解析 LRC 文本：
///  - 支持一行多时间戳 `[00:01.20][00:05.00]text`
///  - 忽略元数据标签（[ar:] [ti:] 等）
///  - 返回按时间升序排列的歌词行
///  - 中文弯引号 '' 归一化为 ASCII '（需求：歌词直引号显示）
List<LyricLine> parseLrc(String raw) {
  final List<LyricLine> lines = <LyricLine>[];
  for (final String rawLine in raw.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;

    final Iterable<RegExpMatch> tags = _tagExp.allMatches(line);
    if (tags.isEmpty) continue;

    final String text =
        line.substring(tags.last.end).trim().replaceAll(_curlyQuoteExp, "'");
    if (text.isEmpty) continue;

    for (final RegExpMatch m in tags) {
      final int minutes = int.parse(m.group(1)!);
      final int seconds = int.parse(m.group(2)!);
      final String msRaw = m.group(3) ?? '0';
      // 兼容两位(厘秒)与三位(毫秒)时间戳
      final int ms = int.parse(msRaw.padRight(3, '0').substring(0, 3));
      lines.add((
        time: Duration(minutes: minutes, seconds: seconds, milliseconds: ms),
        text: text,
      ));
    }
  }
  lines.sort((LyricLine a, LyricLine b) => a.time.compareTo(b.time));
  return lines;
}

/// 二分查找：返回 [position] 时刻应当高亮的歌词下标。
/// 没有任何一行开始时返回 -1。
int activeLyricIndex(List<LyricLine> lines, Duration position) {
  int lo = 0, hi = lines.length - 1, ans = -1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (lines[mid].time <= position) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}
