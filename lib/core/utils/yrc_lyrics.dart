/// 网易云逐字歌词（yrc）解析与定位。
///
/// yrc 格式（/lyric/new → yrc.lyric，实测确认）：
///  - 元数据行（JSON）：`{"t":-1000,"c":[{"tx":"作词: "},{"tx":"某人",...}]}`
///  - 逐字行：`[行start,行dur](字start,字dur,0)字(字start,字dur,0)字...`
///    时间均为毫秒；前奏占位行形如 `[0,12460]`（无字）。
library;

import 'dart:convert';

/// 逐字单元
class YrcWord {
  const YrcWord({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final Duration start;
  final Duration end;

  /// 该字在 [position] 时刻的进度（0..1）
  double progress(Duration position) {
    final int total = end.inMilliseconds - start.inMilliseconds;
    if (total <= 0) return position >= end ? 1.0 : 0.0;
    final int elapsed = position.inMilliseconds - start.inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }
}

/// 一行逐字歌词（含元数据行，UI 据此弱化展示）
class YrcLine {
  const YrcLine({
    required this.start,
    required this.end,
    required this.words,
    this.isMetadata = false,
  });

  final Duration start;
  final Duration end;
  final List<YrcWord> words;
  final bool isMetadata;

  String get text => words.map((YrcWord w) => w.text).join();

  /// 行内当前进度（0..1），未开始返回 0
  double progress(Duration position) {
    final int total = end.inMilliseconds - start.inMilliseconds;
    if (total <= 0) return position >= end ? 1.0 : 0.0;
    final int elapsed = position.inMilliseconds - start.inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }
}

final RegExp _lineHeadExp = RegExp(r'^\[(-?\d+),(-?\d+)\]');
final RegExp _wordExp = RegExp(r'\((-?\d+),(-?\d+),\d+\)([^(]*)');

/// 解析 yrc 原文。容错：JSON 行解析失败直接丢弃该行；
/// 返回按时间升序排列的行列表（元数据行保留，UI 自行降级处理）。
List<YrcLine> parseYrc(String raw) {
  final List<YrcLine> lines = <YrcLine>[];
  for (final String rawLine in raw.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;

    // 1) JSON 元数据行 {"t":...,"c":[{"tx":...}]}
    if (line.startsWith('{')) {
      final YrcLine? meta = _parseMetadataLine(line);
      if (meta != null) lines.add(meta);
      continue;
    }

    // 2) 逐字行 [start,dur](s,d,0)word...
    final RegExpMatch? head = _lineHeadExp.firstMatch(line);
    if (head == null) continue;
    final int startMs = int.parse(head.group(1)!);
    final int durMs = int.parse(head.group(2)!);
    final int endMs = startMs + durMs;

    final List<YrcWord> words = <YrcWord>[];
    for (final RegExpMatch m in _wordExp.allMatches(line)) {
      final int ws = int.parse(m.group(1)!);
      final int wd = int.parse(m.group(2)!);
      // 中文弯引号 '' → ASCII '（需求：与 LRC 解析同规则归一化）
      final String text =
          (m.group(3) ?? '').replaceAll(RegExp('[\u2018\u2019]'), "'");
      if (text.isEmpty) continue;
      words.add(YrcWord(
        text: text,
        start: Duration(milliseconds: ws),
        end: Duration(milliseconds: ws + wd),
      ));
    }
    if (words.isEmpty && durMs <= 0) continue; // 纯噪声行
    lines.add(YrcLine(
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
      words: words,
    ));
  }
  lines.sort((YrcLine a, YrcLine b) => a.start.compareTo(b.start));
  return lines;
}

YrcLine? _parseMetadataLine(String line) {
  try {
    final Object? decoded = jsonDecode(line);
    if (decoded is! Map<String, Object?>) return null;
    final Object? t = decoded['t'];
    final Object? c = decoded['c'];
    if (t is! num || c is! List<Object?>) return null;
    final int tMs = t.toInt();
    final List<YrcWord> words = <YrcWord>[];
    for (final Object? item in c) {
      if (item is Map<String, Object?>) {
        final String? tx = item['tx'] as String?;
        if (tx == null || tx.isEmpty) continue;
        // 元数据行逐字无独立时长：整行共用行时间
        words.add(YrcWord(
          text: tx,
          start: Duration(milliseconds: tMs),
          end: Duration(milliseconds: tMs + 1),
        ));
      }
    }
    if (words.isEmpty) return null;
    return YrcLine(
      start: Duration(milliseconds: tMs),
      end: Duration(milliseconds: tMs + 1),
      words: words,
      isMetadata: true,
    );
  } on FormatException {
    return null;
  }
}

/// 二分查找：返回 [position] 时刻应高亮的行下标（元数据行同样参与）。
/// 没有任何一行开始时返回 -1。
int activeYrcIndex(List<YrcLine> lines, Duration position) {
  int lo = 0, hi = lines.length - 1, ans = -1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (lines[mid].start <= position) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}
