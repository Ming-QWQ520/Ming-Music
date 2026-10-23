/// MingMusic 单元测试：LRC 解析 / 二分查找 / 时间格式化 / Track 序列化 /
/// 翻译就近匹配 / 歌单离线缓存序列化。
///
/// 说明：音频引擎依赖平台通道（AudioService.init），不适合在纯 Dart
/// 测试环境运行，因此本文件聚焦可确定性验证的核心工具层。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/api/netease_models.dart';
import 'package:ming_music/core/utils/duration_utils.dart';
import 'package:ming_music/core/utils/lyrics.dart';
import 'package:ming_music/features/library/domain/track.dart';
import 'package:ming_music/features/player/providers/lyrics_providers.dart';

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

  group('ParsedLyrics 翻译就近匹配', () {
    test('精确命中', () {
      final ParsedLyrics lyrics = ParsedLyrics(
        lrcLines: parseLrc('[00:10.000]Hello world'),
        translations: <int, String>{10000: '你好世界'},
      );
      expect(lyrics.subLineFor(10000), '你好世界');
    });

    test('时间轴整体偏移时就近命中（≤600ms）', () {
      // 修复「部分外语歌不显示翻译」：tlyric 与原文相差几十至几百毫秒
      final ParsedLyrics lyrics = ParsedLyrics(
        lrcLines: parseLrc('[00:10.000]Hello'),
        translations: <int, String>{10420: '你好'},
      );
      expect(lyrics.subLineFor(10000), '你好');
    });

    test('超出容忍度不误配（Zephyr 处理方式：容忍 3.0s）', () {
      // 5.2s 偏移超出 3.0s 容忍度 → 不匹配（旧断言 1.2s 已随 Zephyr 容忍度调整）
      final ParsedLyrics lyrics = ParsedLyrics(
        lrcLines: parseLrc('[00:10.000]Hello'),
        translations: <int, String>{15200: '你好'},
      );
      expect(lyrics.subLineFor(10000), isEmpty);
    });

    test('1.2s 偏移在 Zephyr 容忍度内可匹配', () {
      // Zephyr-Music 处理方式：3.0s 容忍度 —— 1.2s 整体偏移的 tlyric 应命中
      final ParsedLyrics lyrics = ParsedLyrics(
        lrcLines: parseLrc('[00:10.000]Hello'),
        translations: <int, String>{11200: '你好'},
      );
      expect(lyrics.subLineFor(10000), '你好');
    });

    test('多个翻译行取最近的一行', () {
      final ParsedLyrics lyrics = ParsedLyrics(
        lrcLines: parseLrc('[00:20.000]Line'),
        translations: <int, String>{
          19000: '上一行',
          20100: '当前行',
          26000: '下一行',
        },
      );
      expect(lyrics.subLineFor(20000), '当前行');
    });

    test('中文弯引号归一化为 ASCII 直引号（需求）', () {
      final List<LyricLine> lines =
          parseLrc('[00:01.000]I\u2019m OK \u2018hi\u2019');
      expect(lines.single.text, "I'm OK 'hi'");
    });

    test('无翻译时回退音译', () {
      final ParsedLyrics lyrics = ParsedLyrics(
        lrcLines: parseLrc('[00:05.000]アイウエオ'),
        romanizations: <int, String>{5030: 'aiueo'},
      );
      expect(lyrics.subLineFor(5000), 'aiueo');
    });
  });

  group('歌单离线缓存序列化', () {
    test('PlaylistDetail toJson / fromStoredJson 往返一致', () {
      const PlaylistDetail detail = PlaylistDetail(
        meta: PlaylistMeta(
          id: 42,
          name: '测试歌单',
          coverUrl: 'https://p1.music.126.net/x.jpg',
          trackCount: 2,
          creator: '某人',
          creatorUserId: 7,
        ),
        tracks: <Song>[
          Song(
            id: 1,
            name: '歌一',
            artists: '甲',
            album: '专一',
            coverUrl: 'https://p1.music.126.net/a.jpg',
            durationMs: 200000,
            fee: 0,
          ),
          Song(id: 2, name: '歌二', artists: '乙 / 丙', album: '', fee: 1),
        ],
      );
      final Map<String, Object?> encoded = detail.toJson();
      final String json = jsonEncode(encoded); // 必须可 JSON 序列化
      final PlaylistDetail restored =
          PlaylistDetail.fromStoredJson(jsonDecode(json) as Map<String, Object?>);
      expect(restored.meta.id, 42);
      expect(restored.meta.name, '测试歌单');
      expect(restored.meta.creatorUserId, 7);
      expect(restored.tracks.length, 2);
      expect(restored.tracks[0].name, '歌一');
      expect(restored.tracks[0].coverUrl, 'https://p1.music.126.net/a.jpg');
      expect(restored.tracks[0].durationMs, 200000);
      expect(restored.tracks[1].fee, 1);
      expect(restored.tracks[1].artists, '乙 / 丙');
    });
  });
}
