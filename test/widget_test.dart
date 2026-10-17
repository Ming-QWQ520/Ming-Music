/// MingMusic 单元测试：LRC 解析 / 二分查找 / 时间格式化 / Track 序列化。
///
/// 说明：音频引擎依赖平台通道（AudioService.init），不适合在纯 Dart
/// 测试环境运行，因此本文件聚焦可确定性验证的核心工具层。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/utils/duration_utils.dart';
import 'package:ming_music/core/utils/lyrics.dart';
import 'package:ming_music/features/library/domain/track.dart';

void main() {
  group('parseLrc', () {
    test('解析标准 LRC（毫秒三位）', () {
      const String raw = '''
[ar:测试歌手]
[ti:测试曲目]
[00:01.500]第一行
[00:06.000]第二行
[00:12.250]第三行
''';
      final List<LyricLine> lines = parseLrc(raw);
      expect(lines.length, 3);
      expect(lines[0].time, const Duration(milliseconds: 1500));
      expect(lines[0].text, '第一行');
      expect(lines[1].time, const Duration(seconds: 6));
      expect(lines[2].time, const Duration(milliseconds: 12250));
      // 元数据不进入歌词行
      expect(lines.any((LyricLine l) => l.text.contains('ar:')), isFalse);
    });

    test('解析两位厘秒时间戳', () {
      final List<LyricLine> lines = parseLrc('[00:02.20]短毫秒');
      expect(lines.single.time, const Duration(milliseconds: 2200));
    });

    test('一行多时间戳展开为多行', () {
      final List<LyricLine> lines = parseLrc('[00:01.00][00:05.00]副歌重复');
      expect(lines.length, 2);
      expect(lines[0].time, const Duration(seconds: 1));
      expect(lines[1].time, const Duration(seconds: 5));
      expect(lines[1].text, '副歌重复');
    });

    test('输出按时间升序排列', () {
      final List<LyricLine> lines = parseLrc('''
[00:09.00]后
[00:03.00]前
[00:06.00]中
''');
      expect(
          lines.map((LyricLine l) => l.text).toList(), <String>['前', '中', '后']);
    });

    test('忽略无时间戳的行', () {
      final List<LyricLine> lines = parseLrc('纯文本没有标签\n[00:01.00]有标签');
      expect(lines.length, 1);
    });
  });

  group('activeLyricIndex（二分查找）', () {
    final List<LyricLine> lines = parseLrc('''
[00:01.00]A
[00:05.00]B
[00:10.00]C
[00:20.00]D
''');

    test('开始前返回 -1', () {
      expect(activeLyricIndex(lines, const Duration(milliseconds: 999)), -1);
    });

    test('恰好命中时间戳', () {
      expect(activeLyricIndex(lines, const Duration(seconds: 5)), 1);
    });

    test('时间戳之间取上一行', () {
      expect(activeLyricIndex(lines, const Duration(seconds: 7)), 1);
    });

    test('最后一行之后仍高亮最后一行', () {
      expect(activeLyricIndex(lines, const Duration(seconds: 99)), 3);
    });

    test('空列表安全', () {
      expect(activeLyricIndex(<LyricLine>[], const Duration(seconds: 1)), -1);
    });
  });

  group('DurationX.clock', () {
    test('分秒格式', () {
      expect(const Duration(seconds: 65).clock, '1:05');
      expect(const Duration(seconds: 5).clock, '0:05');
    });

    test('超过一小时', () {
      expect(const Duration(hours: 1, minutes: 2, seconds: 3).clock, '1:02:03');
    });
  });

  group('Track 序列化', () {
    test('toMap / fromMap 往返一致', () {
      const Track source = Track(
        id: 'net_1',
        title: '网络曲目',
        artist: '某歌手',
        album: '网络直链',
        source: 'https://example.com/a.mp3',
        isNetwork: true,
        isCustom: true,
        durationMs: 12000,
      );
      final Track restored = Track.fromMap(source.toMap());
      expect(restored.id, source.id);
      expect(restored.title, source.title);
      expect(restored.artist, source.artist);
      expect(restored.source, source.source);
      expect(restored.isNetwork, isTrue);
      expect(restored.durationMs, 12000);
    });

    test('相等性由 id 决定', () {
      const Track a =
          Track(id: 'x', title: 'a', artist: 'b', album: 'c', source: 's');
      const Track b =
          Track(id: 'x', title: 'b', artist: 'c', album: 'd', source: 't');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
