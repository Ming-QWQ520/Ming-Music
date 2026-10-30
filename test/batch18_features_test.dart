/// 第十八批新增功能单元测试：
///  1. /song/url/v1 响应元数据解析（level 实际下发档位 / sr 实际采样率，
///     需求：播放设置音质项显示真实频率与真实品质）；
///  2. 音质档位全量 10 档（songurl.txt：hires/jyeffect/dolby/vivid/
///     jymaster/sky）的展示名 / 短名 / api 值；
///  3. 真实品质/频率展示辅助（audioQualityLevelLabel / formatSampleRate）；
///  4. 我的页歌单缓存往返（含 lastUserId 键注册，离线直显链路）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/api/netease_models.dart';
import 'package:ming_music/core/storage/prefs_keys.dart';
import 'package:ming_music/features/auth/data/netease_auth_repository.dart';
import 'package:ming_music/features/settings/domain/settings_models.dart'
    show AudioQuality, AudioQualityX, audioQualityLevelLabel, formatSampleRate;

void main() {
  group('SongUrlInfo 真实音质元数据（level/sr）', () {
    test('解析 level 与 sr 字段（权限回落场景：请求无损实际返回极高）', () {
      const String payload =
          '{"id":1969519579,"url":"http://m801.music.126.net/x.mp3",'
          '"br":320000,"size":8798445,"type":"mp3","fee":8,'
          '"level":"exhigh","sr":48000}';
      final SongUrlInfo info =
          SongUrlInfo.fromJson(parseJsonMap(payload));
      expect(info.level, 'exhigh');
      expect(info.sr, 48000);
      expect(info.br, 320000);
      expect(info.playable, isTrue);
    });

    test('缺失 level/sr 的旧结构不崩（字段可空）', () {
      const String payload =
          '{"id":123,"url":"https://m7.music.126.net/y.flac","br":995000}';
      final SongUrlInfo info =
          SongUrlInfo.fromJson(parseJsonMap(payload));
      expect(info.level, isNull);
      expect(info.sr, isNull);
    });
  });

  group('AudioQuality 全量 10 档（songurl.txt）', () {
    test('档位集合与官方 level 参数一致', () {
      expect(
        AudioQuality.values.map((AudioQuality q) => q.apiValue).toList(),
        <String>[
          'standard',
          'higher',
          'exhigh',
          'lossless',
          'hires',
          'jyeffect',
          'dolby',
          'vivid',
          'jymaster',
          'sky',
        ],
      );
    });

    test('新档位完整展示名（选择面板/更多菜单）', () {
      expect(AudioQuality.hires.label, 'Hi-Res');
      expect(AudioQuality.jyeffect.label, '高清臻音');
      expect(AudioQuality.dolby.label, '杜比全景声');
      expect(AudioQuality.vivid.label, '臻音全景声');
      expect(AudioQuality.jymaster.label, '超清母带');
      expect(AudioQuality.sky.label, '沉浸环绕声');
      // 旧档位不受影响
      expect(AudioQuality.standard.label, '标准 (128K)');
      expect(AudioQuality.lossless.label, '无损 FLAC');
    });

    test('新档位短名（进度行中央音质胶囊）', () {
      expect(AudioQuality.hires.shortLabel, 'Hi-Res');
      expect(AudioQuality.jyeffect.shortLabel, '臻音');
      expect(AudioQuality.dolby.shortLabel, '杜比');
      expect(AudioQuality.vivid.shortLabel, '全景声');
      expect(AudioQuality.jymaster.shortLabel, '母带');
      expect(AudioQuality.sky.shortLabel, '环绕声');
    });

    test('fromName 兼容历史存档（未知名回落 standard）', () {
      expect(AudioQualityX.fromName('lossless'), AudioQuality.lossless);
      expect(AudioQualityX.fromName('sky'), AudioQuality.sky);
      expect(AudioQualityX.fromName('unknown-v99'), AudioQuality.standard);
      expect(AudioQualityX.fromName(null), AudioQuality.standard);
    });
  });

  group('真实品质/频率展示辅助', () {
    test('audioQualityLevelLabel：实际下发档位 → 展示名', () {
      expect(audioQualityLevelLabel('exhigh'), '极高');
      expect(audioQualityLevelLabel('lossless'), '无损');
      expect(audioQualityLevelLabel('hires'), 'Hi-Res');
      expect(audioQualityLevelLabel('jymaster'), '超清母带');
      expect(audioQualityLevelLabel('sky'), '沉浸环绕声');
      expect(audioQualityLevelLabel(null), '');
      expect(audioQualityLevelLabel(''), '');
      // 未知档位原样透出（不虚构）
      expect(audioQualityLevelLabel('mystery'), 'mystery');
    });

    test('formatSampleRate：采样率 → 展示串', () {
      expect(formatSampleRate(44100), '44.1kHz');
      expect(formatSampleRate(48000), '48kHz');
      expect(formatSampleRate(96000), '96kHz');
      expect(formatSampleRate(192000), '192kHz');
      expect(formatSampleRate(null), '');
      expect(formatSampleRate(0), '');
    });
  });

  group('我的页歌单缓存（离线直显链路）', () {
    test('lastUserId 键已注册（离线拆分创建/收藏歌单依赖）', () {
      expect(PrefsKeys.lastUserId, 'library.lastUserId');
      // 缓存键与登出清理键保持一致（防漂移）
      expect(
        PrefsKeys.libraryUserPlaylistsCache,
        'library.userPlaylistsCache',
      );
    });

    test('NeteaseUserPlaylist 缓存往返保留 creatorUserId', () {
      const NeteaseUserPlaylist p = NeteaseUserPlaylist(
        id: 888,
        name: '我的离线歌单',
        coverUrl: 'https://p1.music.126.net/c.jpg',
        trackCount: 12,
        creatorUserId: 192413597,
      );
      final NeteaseUserPlaylist back =
          NeteaseUserPlaylist.fromCacheMap(p.toCacheMap());
      expect(back.id, 888);
      expect(back.name, '我的离线歌单');
      expect(back.creatorUserId, 192413597);
      expect(back.trackCount, 12);
    });
  });
}

/// 测试辅助：解析 JSON 对象串为 `Map<String, Object?>`
Map<String, Object?> parseJsonMap(String raw) =>
    (jsonDecode(raw) as Map<Object?, Object?>).cast<String, Object?>();
