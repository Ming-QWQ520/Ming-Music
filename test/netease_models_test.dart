/// 网易云模型解析测试：Song（cloudsearch/search 双格式）/ PlaylistMeta /
/// SongUrlInfo / LyricData。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/api/netease_models.dart';
import 'package:ming_music/features/library/domain/track.dart';

void main() {
  group('Song.fromCloudJson', () {
    test('cloudsearch 字段（ar/al/dt）', () {
      final Song s = Song.fromCloudJson(<String, Object?>{
        'id': 449818741,
        'name': '光年之外',
        'ar': <Object?>[
          <String, Object?>{'id': 7763, 'name': 'G.E.M.邓紫棋'},
        ],
        'al': <String, Object?>{
          'id': 347230,
          'name': '光年之外',
          'picUrl': 'http://p3.music.126.net/xx.jpg',
        },
        'dt': 227640,
        'fee': 8,
      });
      expect(s.id, 449818741);
      expect(s.name, '光年之外');
      expect(s.artists, 'G.E.M.邓紫棋');
      expect(s.album, '光年之外');
      expect(s.coverUrl, 'http://p3.music.126.net/xx.jpg');
      expect(s.durationMs, 227640);
      expect(s.isVipOnly, isFalse);
    });

    test('旧版 search 字段（artists/album/duration）', () {
      final Song s = Song.fromCloudJson(<String, Object?>{
        'id': 1,
        'name': '大眠',
        'artists': <Object?>[
          <String, Object?>{'name': '王心凌'},
          <String, Object?>{'name': 'Cyndi'},
        ],
        'album': <String, Object?>{'name': 'CYNDILOVES2SING '},
        'duration': 260000,
        'fee': 1,
      });
      expect(s.artists, '王心凌 / Cyndi');
      expect(s.durationMs, 260000);
      expect(s.isVipOnly, isTrue);
    });

    test('toTrack 生成待解析直链的队列条目', () {
      final Song s = Song.fromCloudJson(<String, Object?>{
        'id': 42,
        'name': '测试',
        'ar': <Object?>[
          <String, Object?>{'name': 'A'}
        ],
      });
      final Track t = s.toTrack();
      expect(t.neteaseId, 42);
      expect(t.source, '');
      expect(t.needsUrlResolve, isTrue);
      expect(t.id, 'netease_42');
    });
  });

  group('PlaylistMeta.fromJson', () {
    test('解析封面/播放量/创建者', () {
      final PlaylistMeta p = PlaylistMeta.fromJson(<String, Object?>{
        'id': 3778678,
        'name': '热歌榜',
        'coverImgUrl': 'http://p1.music.126.net/cover.jpg',
        'playCount': 25310000000,
        'trackCount': 100,
        'creator': <String, Object?>{'nickname': '云音乐官方'},
      });
      expect(p.id, 3778678);
      expect(p.name, '热歌榜');
      expect(p.playCount, 25310000000);
      expect(p.trackCount, 100);
      expect(p.creator, '云音乐官方');
    });
  });

  group('SongUrlInfo.fromJson', () {
    test('可播直链 + 试听标记', () {
      final SongUrlInfo u = SongUrlInfo.fromJson(<String, Object?>{
        'id': 1374012583,
        'url': 'http://m701.music.126.net/x.mp3',
        'br': 128000,
        'type': 'mp3',
        'fee': 8,
        'freeTrialInfo': <String, Object?>{'start': 0, 'end': 30000},
      });
      expect(u.playable, isTrue);
      expect(u.isTrial, isTrue);
    });

    test('VIP 无链接 → 不可播', () {
      final SongUrlInfo u = SongUrlInfo.fromJson(<String, Object?>{
        'id': 1,
        'url': null,
        'fee': 1,
        'freeTrialInfo': null,
      });
      expect(u.playable, isFalse);
    });
  });

  group('Track 序列化往返', () {
    test('网易云曲目 toMap/fromMap 字段保全', () {
      const Track t = Track(
        id: 'netease_449818741',
        neteaseId: 449818741,
        title: '光年之外',
        artist: 'G.E.M.邓紫棋',
        album: '光年之外',
        source: '',
        cover: 'http://p3.music.126.net/xx.jpg',
        durationMs: 227640,
        isNetwork: true,
        fee: 8,
      );
      final Track restored = Track.fromMap(t.toMap());
      expect(restored.neteaseId, t.neteaseId);
      expect(restored.title, t.title);
      expect(restored.fee, t.fee);
      expect(restored.needsUrlResolve, isTrue);
    });
  });
}
