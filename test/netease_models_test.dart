/// 网易云模型解析测试：Song（cloudsearch/search 双格式）/ PlaylistMeta /
/// SongUrlInfo / LyricData。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/api/netease_api.dart';
import 'package:ming_music/core/api/netease_models.dart';
import 'package:ming_music/features/library/domain/track.dart';

void main() {
  group('normalizeNeteaseUrl（明文直链改写，播放/封面加载根因修复）', () {
    test('music.126.net http → https', () {
      expect(
        normalizeNeteaseUrl('http://m702.music.126.net/a/b.mp3'),
        'https://m702.music.126.net/a/b.mp3',
      );
      expect(
        normalizeNeteaseUrl('http://p3.music.126.net/x.jpg'),
        'https://p3.music.126.net/x.jpg',
      );
    });

    test('已是 https / 非 CDN 域名 / 空值不变', () {
      expect(
        normalizeNeteaseUrl('https://m801.music.126.net/a.mp3'),
        'https://m801.music.126.net/a.mp3',
      );
      expect(
        normalizeNeteaseUrl('http://example.com/a.mp3'),
        'http://example.com/a.mp3',
      );
      expect(normalizeNeteaseUrl(null), '');
      expect(normalizeNeteaseUrl(''), '');
    });

    test('Song 模型封面自动改写 https', () {
      final Song s = Song.fromCloudJson(<String, Object?>{
        'id': 1,
        'name': 'x',
        'ar': <Object?>[
          <String, Object?>{'id': 1, 'name': 'a'},
        ],
        'al': <String, Object?>{
          'id': 1,
          'name': 'al',
          'picUrl': 'http://p2.music.126.net/c.jpg',
        },
      });
      expect(s.coverUrl, 'https://p2.music.126.net/c.jpg');
    });

    test('SongUrlInfo 直链自动改写 https', () {
      final SongUrlInfo u = SongUrlInfo.fromJson(<String, Object?>{
        'id': 1,
        'url': 'http://m701.music.126.net/x.mp3',
      });
      expect(u.url, 'https://m701.music.126.net/x.mp3');
      expect(u.playable, isTrue);
    });
  });

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
      expect(s.coverUrl, 'https://p3.music.126.net/xx.jpg');
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

  group('搜索分类模型（第十四批：/search type 全量）', () {
    test('SearchAlbum：artist 嵌套对象 / size→songCount / picUrl 归一化', () {
      final SearchAlbum a = SearchAlbum.fromJson(<String, Object?>{
        'id': 18909,
        'name': 'Partners 拍档',
        'size': 13,
        'publishTime': 1507046400000,
        'artist': <String, Object?>{'id': 6452, 'name': '周杰伦'},
        'picUrl': 'http://p4.music.126.net/abc.jpg',
      });
      expect(a.id, 18909);
      expect(a.name, 'Partners 拍档');
      expect(a.artist, '周杰伦');
      expect(a.songCount, 13);
      expect(a.picUrl, isNotNull);
      expect(a.picUrl!.startsWith('https://'), isTrue);
    });

    test('SearchAlbum：artist 缺失回退未知歌手', () {
      final SearchAlbum a = SearchAlbum.fromJson(<String, Object?>{
        'id': 1,
        'name': 'X',
      });
      expect(a.artist, '未知歌手');
      expect(a.picUrl, isNull);
    });

    test('SearchArtist：alias 字符串数组拼接 / img1v1Url 兜底', () {
      final SearchArtist ar = SearchArtist.fromJson(<String, Object?>{
        'id': 6452,
        'name': '周杰伦',
        'alias': <Object?>['Jay Chou', '周董'],
        'albumSize': 42,
        'musicSize': 582,
        'mvSize': 9,
      });
      expect(ar.alias, 'Jay Chou / 周董');
      expect(ar.albumSize, 42);
      expect(ar.picUrl, isNull); // 无 picUrl/img1v1Url
      final SearchArtist ar2 = SearchArtist.fromJson(<String, Object?>{
        'id': 7,
        'name': 'A',
        'img1v1Url': 'http://p4.music.126.net/vv.jpg',
      });
      expect(ar2.picUrl, isNotNull);
      expect(ar2.picUrl!.startsWith('https://'), isTrue);
    });

    test('SearchUser：userId 缺失回退 id 字段', () {
      final SearchUser u1 = SearchUser.fromJson(<String, Object?>{
        'userId': 98693,
        'nickname': '音乐',
        'signature': '签名',
      });
      expect(u1.userId, 98693);
      expect(u1.signature, '签名');
      final SearchUser u2 = SearchUser.fromJson(<String, Object?>{
        'id': 42,
        'nickname': 'N',
      });
      expect(u2.userId, 42);
      expect(u2.signature, '');
    });

    test('SearchMv：duration/playCount/cover 解析', () {
      final SearchMv m = SearchMv.fromJson(<String, Object?>{
        'id': 4909,
        'name': 'MV',
        'artistName': '周杰伦',
        'cover': 'http://p4.music.126.net/mv.jpg',
        'duration': 54000,
        'playCount': 436191,
      });
      expect(m.id, 4909);
      expect(m.durationMs, 54000);
      expect(m.playCount, 436191);
      expect(m.coverUrl, isNotNull);
      expect(m.coverUrl!.startsWith('https://'), isTrue);
    });

    test('SearchResults.isEmpty：全空为 true，任一列表非空为 false', () {
      const SearchResults empty = SearchResults(type: 1018);
      expect(empty.isEmpty, isTrue);
      const SearchResults onlySongs = SearchResults(
        type: 1,
        songs: <Song>[Song(id: 1, name: 'a', artists: 'b', album: 'c')],
      );
      expect(onlySongs.isEmpty, isFalse);
    });
  });
}
