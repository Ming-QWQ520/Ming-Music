/// 第二十八批测试：音乐获取双模式设置项。
///
/// 背景链：网易云 /song/url/v1 直链 expi=1200 秒（20 分钟）过期，
/// 内核装载陈旧直链 → CDN 403 → 播放拉断。本批在既有三层防护
///（timestamp 穿透 / 守卫阈值续取 / 内核错误自愈）之上新增「音乐获取」
/// 设置项 —— 按需（默认）/ 重定向两种模式：
///  - 按需：沿用现有防护链；
///  - 重定向：播放器直连 `/song/url/v1/302?id=&level=` 端点，服务端
///    每次连接实时 302 到当次有效直链，客户端直链永不过期。
///
/// 覆盖：
///  - MusicFetchModeX.fromName：合法值 / 非法值 / 缺省默认按需；
///  - MusicFetchModeNotifier：未持久化默认按需 / redirect 持久化读取；
///  - NeteaseApi.buildGetUrl：302 端点 URL 组装（id/level/timestamp）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ming_music/core/api/netease_api.dart';
import 'package:ming_music/features/settings/domain/settings_models.dart';
import 'package:ming_music/features/settings/providers/settings_providers.dart';

void main() {
  group('MusicFetchMode 反序列化（设置项持久化）', () {
    test('onDemand 名称解析', () {
      expect(MusicFetchModeX.fromName('onDemand'), MusicFetchMode.onDemand);
    });

    test('redirect 名称解析', () {
      expect(MusicFetchModeX.fromName('redirect'), MusicFetchMode.redirect);
    });

    test('非法值 → 默认按需（需求：默认按需）', () {
      expect(MusicFetchModeX.fromName('bogus'), MusicFetchMode.onDemand);
      expect(MusicFetchModeX.fromName(null), MusicFetchMode.onDemand);
    });

    test('展示文案（label/subtitle）', () {
      expect(MusicFetchMode.onDemand.label, '按需');
      expect(MusicFetchMode.redirect.label, '重定向');
      expect(MusicFetchMode.onDemand.subtitle, contains('自动续取'));
      expect(MusicFetchMode.redirect.subtitle, contains('永不过期'));
    });

    test('未持久化时 MusicFetchModeNotifier 默认按需', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
      final MusicFetchMode mode = container.read(musicFetchModeProvider);
      expect(mode, MusicFetchMode.onDemand);
    });

    test('持久化 redirect 后读取为重定向', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'player.musicFetchMode': 'redirect',
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(musicFetchModeProvider), MusicFetchMode.redirect);
    });

    test('set 持久化写回', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
      container.read(musicFetchModeProvider.notifier).set(
            MusicFetchMode.redirect,
          );
      expect(container.read(musicFetchModeProvider), MusicFetchMode.redirect);
      expect(prefs.getString('player.musicFetchMode'), 'redirect');
    });
  });

  group('NeteaseApi.buildGetUrl（302 端点 URL 组装）', () {
    test('拼出 /song/url/v1/302 端点，含 id/level/timestamp', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final NeteaseApi api =
          NeteaseApi(await SharedPreferences.getInstance());
      final String url = await api.buildGetUrl('/song/url/v1/302',
          <String, String>{'id': '33894312', 'level': 'standard'});
      expect(url.startsWith('${NeteaseApi.baseUrl}/song/url/v1/302?'), isTrue);
      expect(url.contains('id=33894312'), isTrue);
      expect(url.contains('level=standard'), isTrue);
      expect(url.contains('timestamp='), isTrue);
    });

    test('timestamp 为毫秒级整数（防服务端 2 分钟缓存回显旧直链）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final NeteaseApi api =
          NeteaseApi(await SharedPreferences.getInstance());
      final String url = await api
          .buildGetUrl('/song/url/v1/302', <String, String>{'id': '1'});
      final RegExpMatch? m =
          RegExp(r'timestamp=(\d{13,})').firstMatch(url);
      expect(m, isNotNull);
    });
  });
}
