/// 逐字歌词（yrc）解析测试 —— 基于实测网易云 /lyric/new 返回格式。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/utils/yrc_lyrics.dart';

void main() {
  const String sample = '''
{"t":-1000,"c":[{"tx":"作词: "},{"tx":"G.E.M.邓紫棋","li":"http://p1.music.126.net/x.jpg","or":"orpheus://nm/artist/home?id=7763&type=artist"}]}
{"t":-750,"c":[{"tx":"作曲: "},{"tx":"G.E.M.邓紫棋"}]}
[0,12460](0,2490,0)编(2490,2490,0)曲 (4980,2490,0): (7470,2490,0)Lupo (9960,2500,0)Groinig
[12460,3430](12460,500,0)记(12960,480,0)得(13440,600,0)雨(14040,850,0)中
''';

  group('parseYrc', () {
    test('解析元数据行（JSON 行）', () {
      final List<YrcLine> lines = parseYrc(sample);
      expect(lines.length, 4);
      expect(lines[0].isMetadata, isTrue);
      expect(lines[0].start, const Duration(milliseconds: -1000));
      expect(lines[0].text, '作词: G.E.M.邓紫棋');
    });

    test('解析逐字行（毫秒时间与文本切分）', () {
      final List<YrcLine> lines = parseYrc(sample);
      final YrcLine l2 = lines[2];
      expect(l2.isMetadata, isFalse);
      expect(l2.start, Duration.zero);
      expect(l2.end, const Duration(milliseconds: 12460));
      expect(l2.words.length, 5);
      expect(l2.words[0].text, '编');
      expect(l2.words[0].start, Duration.zero);
      expect(l2.words[0].end, const Duration(milliseconds: 2490));
      expect(l2.words[2].text, ': ');
      expect(l2.words[3].text, 'Lupo ');
    });

    test('行排序按开始时间', () {
      final List<YrcLine> lines = parseYrc(sample);
      for (int i = 1; i < lines.length; i++) {
        expect(
          lines[i].start.compareTo(lines[i - 1].start),
          isNonNegative,
          reason: '行 $i 时间必须不小于前一行',
        );
      }
    });

    test('容错：非法 JSON 行被丢弃', () {
      final List<YrcLine> lines =
          parseYrc('{bad json}\n[100,200](100,200,0)你好');
      expect(lines.length, 1);
      expect(lines.single.text, '你好');
    });
  });

  group('activeYrcIndex', () {
    final List<YrcLine> lines = parseYrc(sample);

    test('未开始返回 -1', () {
      expect(
        activeYrcIndex(lines, const Duration(milliseconds: -2000)),
        -1,
      );
    });

    test('命中逐字行', () {
      expect(
        activeYrcIndex(lines, const Duration(milliseconds: 13000)),
        3,
      );
    });

    test('前奏区间命中占位行', () {
      expect(
        activeYrcIndex(lines, const Duration(milliseconds: 6000)),
        2,
      );
    });
  });

  group('YrcWord.progress / YrcLine.progress', () {
    test('字进度单调且收敛于 0..1', () {
      final List<YrcLine> lines = parseYrc(sample);
      final YrcWord w = lines[3].words[1];
      expect(w.progress(const Duration(milliseconds: 12900)), 0.0);
      expect(
        w.progress(const Duration(milliseconds: 13200)),
        greaterThan(0),
      );
      expect(
        w.progress(const Duration(milliseconds: 15000)),
        1.0,
      );
    });
  });
}
