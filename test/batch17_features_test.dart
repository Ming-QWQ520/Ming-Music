/// 第十七批新增功能单元测试：
///  1. 搜索联想词模型解析（entity_card 直 hit / 高亮分段 / 标签 / 相关搜索）；
///  2. 更新服务版本比对（isNewer 逐段比较，短段补 0，v 前缀剥离）；
///  3. 热搜词 iconType 解析（榜单行红色上升箭头数据源）；
///  4. 我的页歌单缓存序列化（toCacheMap/fromCacheMap 往返）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/api/netease_models.dart';
import 'package:ming_music/features/auth/data/netease_auth_repository.dart';
import 'package:ming_music/features/settings/services/app_update_service.dart';

void main() {
  group('搜索联想词解析（KeywordSuggest）', () {
    test('官方结构：直 hit 歌曲卡 + 高亮分段 + 标签 + 相关搜索', () {
      const String payload = '{"code":200,"data":{"demote":false,'
          '"recTitle":"相关搜索",'
          '"recs":[{"keyword":"如果呢 DJ版"},{"keyword":"如果呢 阿悄"}],'
          '"suggests":['
          '{"resourceType":"entity_card","keyword":"如果呢",'
          '"highLightInfo":"[{\\"text\\":\\"如果呢\\",\\"highLighted\\":true}]",'
          '"tag":"原唱",'
          '"relatedResource":{"baseInfo":{"simpleSongData":{'
          '"id":1901371647,"name":"如果呢","fee":8,"dt":231000,'
          '"ar":[{"id":29051613,"name":"郑润泽"}],'
          '"al":{"id":149211843,"name":"如果呢","picUrl":"https://p1.music.126.net/cover.jpg"}}}}},'
          '{"keyword":"如果呢","tag":"热搜",'
          '"highLightInfo":"[{\\"text\\":\\"如果呢\\",\\"highLighted\\":true}]"},'
          '{"keyword":"如果呢DJ",'
          '"highLightInfo":"[{\\"text\\":\\"如果呢\\",\\"highLighted\\":true},'
          '{\\"text\\":\\"DJ\\",\\"highLighted\\":false}]"}'
          ']}}';

      final KeywordSuggest s = keywordSuggestFromPayload(payload);
      expect(s.directHit, isNotNull);
      expect(s.directHit!.directHit, isNotNull);
      expect(s.directHit!.directHit!.id, 1901371647);
      expect(s.directHit!.directHit!.name, '如果呢');
      expect(s.directHit!.directHit!.artists, '郑润泽');
      expect(s.directHit!.directHit!.coverUrl, isNotNull);
      expect(s.directHit!.tag, '原唱');
      expect(s.words.length, 2);
      expect(s.words[0].keyword, '如果呢');
      expect(s.words[0].tag, '热搜');
      expect(s.words[1].keyword, '如果呢DJ');
      expect(s.words[1].segments.length, 2);
      expect(s.words[1].segments[0].highlighted, isTrue);
      expect(s.words[1].segments[1].text, 'DJ');
      expect(s.words[1].segments[1].highlighted, isFalse);
      expect(s.recTitle, '相关搜索');
      expect(s.recs, <String>['如果呢 DJ版', '如果呢 阿悄']);
      expect(s.isEmpty, isFalse);
    });

    test('脏数据容忍：suggests 缺失/分段 JSON 损坏不抛异常', () {
      final KeywordSuggest s1 =
          keywordSuggestFromPayload('{"code":200,"data":{}}');
      expect(s1.isEmpty, isTrue);

      final KeywordSuggest s2 =
          keywordSuggestFromPayload('{"code":200,"data":{"suggests":['
              '{"keyword":"断词","highLightInfo":"not-json"}]}}');
      expect(s2.words.single.keyword, '断词');
      expect(s2.words.single.segments, isEmpty);

      final KeywordSuggest s3 =
          keywordSuggestFromPayload('{"code":400,"msg":"err"}');
      expect(s3.isEmpty, isTrue);
    });
  });

  group('更新服务版本比对（AppUpdateService.isNewer）', () {
    test('常规升/降/等号判定', () {
      expect(AppUpdateService.isNewer('v1.1.1', '1.1.0'), isTrue);
      expect(AppUpdateService.isNewer('1.2.0', 'v1.1.9'), isTrue);
      expect(AppUpdateService.isNewer('v2.0.0', '1.9.9'), isTrue);
      expect(AppUpdateService.isNewer('v1.1.0', '1.1.0'), isFalse);
      expect(AppUpdateService.isNewer('v1.0.9', '1.1.0'), isFalse);
    });

    test('段数不同补 0 与前后缀剥离', () {
      expect(AppUpdateService.isNewer('1.2', '1.1.5'), isTrue);
      expect(AppUpdateService.isNewer('1.1', '1.1.0'), isFalse);
      expect(AppUpdateService.isNewer('v1.1.1-beta', '1.1.0'), isTrue);
      expect(AppUpdateService.isNewer('v1.1.0+2', '1.1.0'), isFalse);
    });

    test('版本号分段解析', () {
      expect(AppUpdateService.versionParts('v1.2.3'), <int>[1, 2, 3]);
      expect(AppUpdateService.versionParts('1.2.3-beta.4'), <int>[1, 2, 3]);
    });
  });

  group('热搜词 iconType 解析', () {
    test('iconType=1 记为上升（榜单行红色箭头数据源）', () {
      final HotWord w = HotWord.fromJson(<String, Object?>{
        'searchWord': '雨爱',
        'score': 986532.5,
        'iconType': 1,
      });
      expect(w.word, '雨爱');
      expect(w.iconType, 1);
      expect(w.score, closeTo(986532.5, 0.01));

      final HotWord plain = HotWord.fromJson(<String, Object?>{
        'searchWord': '天龙八部之宿敌',
      });
      expect(plain.iconType, 0);
    });
  });

  group('我的页歌单缓存序列化', () {
    test('toCacheMap/fromCacheMap 往返', () {
      const NeteaseUserPlaylist p = NeteaseUserPlaylist(
        id: 8845321,
        name: '国语',
        coverUrl: 'https://p1.music.126.net/pl.jpg',
        trackCount: 42,
        creatorUserId: 123456,
        playCount: 900,
        description: '自建',
      );
      final NeteaseUserPlaylist restored =
          NeteaseUserPlaylist.fromCacheMap(p.toCacheMap());
      expect(restored.id, 8845321);
      expect(restored.name, '国语');
      expect(restored.coverUrl, 'https://p1.music.126.net/pl.jpg');
      expect(restored.trackCount, 42);
      expect(restored.creatorUserId, 123456);
      expect(restored.playCount, 900);
      expect(restored.description, '自建');
    });

    test('脏数据兜底：空 map 不抛异常', () {
      final NeteaseUserPlaylist p =
          NeteaseUserPlaylist.fromCacheMap(<String, Object?>{});
      expect(p.id, 0);
      expect(p.name, '');
    });
  });
}

/// 测试辅助：从 JSON 字符串解析 KeywordSuggest（与仓库层解析同构，
/// 避免为单测引入带 SharedPreferences 依赖的 NeteaseRepository）
KeywordSuggest keywordSuggestFromPayload(String raw) {
  // ignore: avoid_dynamic_calls
  final Object? decoded = _jsonDecode(raw);
  if (decoded is! Map<String, Object?>) return const KeywordSuggest();
  final Object? data = decoded['data'];
  if (data is! Map<String, Object?>) return const KeywordSuggest();
  final List<SuggestWord> words = <SuggestWord>[];
  SuggestWord? directHit;
  final Object? suggests = data['suggests'];
  if (suggests is List<Object?>) {
    for (final Object? item in suggests) {
      if (item is! Map<String, Object?>) continue;
      final SuggestWord w = SuggestWord.fromJson(item);
      if (w.keyword.isEmpty && !w.isDirectHit) continue;
      if (w.isDirectHit && directHit == null) {
        directHit = w;
      } else {
        words.add(w);
      }
    }
  }
  final List<String> recs = <String>[];
  final Object? rawRecs = data['recs'];
  if (rawRecs is List<Object?>) {
    for (final Object? item in rawRecs) {
      if (item is String && item.isNotEmpty) {
        recs.add(item);
      } else if (item is Map<String, Object?>) {
        final String? kw = item['keyword'] as String?;
        if (kw != null && kw.isNotEmpty) recs.add(kw);
      }
    }
  }
  return KeywordSuggest(
    directHit: directHit,
    words: words,
    recTitle: (data['recTitle'] as String?) ?? '相关搜索',
    recs: recs,
  );
}

Object? _jsonDecode(String raw) => jsonDecode(raw);
