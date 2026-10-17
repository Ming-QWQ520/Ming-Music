/// 网易云数据仓库：搜索 / 热搜 / 推荐歌单 / 歌单详情 / 榜单 / 播放地址 / 歌词。
///
/// 榜单入口采用官方固定 id 静态配置（避免依赖 toplists 接口的偶发慢查询），
/// 详情统一走 /playlist/detail（榜单与歌单同构）。
library;

import '../../../core/api/netease_api.dart';
import '../../../core/api/netease_models.dart';

/// 榜单入口（官方固定 id）
class ToplistConf {
  const ToplistConf(
      {required this.id, required this.name, required this.color});

  final int id;
  final String name;

  /// 排行榜卡片的渐变主色（参考图1 榜单卡片区配色）
  final int color;
}

const List<ToplistConf> kToplists = <ToplistConf>[
  ToplistConf(id: 19723756, name: '飙升榜', color: 0xFFE2483D),
  ToplistConf(id: 3778678, name: '热歌榜', color: 0xFFDF468B),
  ToplistConf(id: 3779629, name: '新歌榜', color: 0xFFEB7524),
  ToplistConf(id: 2884035, name: '原创榜', color: 0xFF8F5BDB),
  ToplistConf(id: 71384707, name: '说唱榜', color: 0xFF2E7CF6),
  ToplistConf(id: 745956260, name: 'ACG 榜', color: 0xFF27AE60),
];

class NeteaseRepository {
  NeteaseRepository(this._api);

  final NeteaseApi _api;

  /// 搜索（cloudsearch 字段更全：fee/dt/picUrl）
  Future<List<Song>> search(String keywords, {int limit = 30}) async {
    final Map<String, Object?> res =
        await _api.get('/cloudsearch', <String, String>{
      'keywords': keywords,
      'limit': '$limit',
      'offset': '0',
      'type': '1',
    });
    final Object? data = res['data'];
    final Object? songs = (data is Map<String, Object?>) ? data['songs'] : null;
    return _songsFrom(songs);
  }

  /// 热搜词（详细版，带icon与热度）
  Future<List<HotWord>> hotSearch() async {
    final Map<String, Object?> res =
        await _api.get('/search/hot/detail', const <String, String>{});
    final Object? data = res['data'];
    if (data is! List<Object?>) return const <HotWord>[];
    return data
        .whereType<Map<String, Object?>>()
        .map(HotWord.fromJson)
        .where((HotWord w) => w.word.isNotEmpty)
        .toList(growable: false);
  }

  /// 推荐歌单（游客可用）
  Future<List<PlaylistMeta>> personalized({int limit = 10}) async {
    final Map<String, Object?> res =
        await _api.get('/personalized', <String, String>{'limit': '$limit'});
    final Object? result = res['result'];
    if (result is! List<Object?>) return const <PlaylistMeta>[];
    return result
        .whereType<Map<String, Object?>>()
        .map(PlaylistMeta.fromJson)
        .where((PlaylistMeta p) => p.id != 0)
        .toList(growable: false);
  }

  /// 歌单详情（榜单同构，亦复用此接口）
  Future<PlaylistDetail> playlistDetail(int id) async {
    final Map<String, Object?> res =
        await _api.get('/playlist/detail', <String, String>{'id': '$id'});
    final Object? playlist = res['playlist'];
    if (playlist is! Map<String, Object?>) {
      throw ApiException('歌单不存在或已下架');
    }
    final PlaylistMeta meta = PlaylistMeta.fromJson(playlist);
    final List<Song> tracks = _songsFrom(playlist['tracks']);
    // 部分歌单 tracks 只返回前 8 条，trackIds 补全（歌曲名等信息后续按需拉取）
    if (tracks.isEmpty) {
      final Object? trackIds = playlist['trackIds'];
      if (trackIds is List<Object?>) {
        return PlaylistDetail(meta: meta, tracks: const <Song>[]);
      }
    }
    return PlaylistDetail(meta: meta, tracks: tracks);
  }

  /// 榜单详情（同歌单接口）
  Future<PlaylistDetail> toplist(int id) => playlistDetail(id);

  /// 批量解析播放地址（/song/url/v1 支持逗号分隔多 id）。
  /// 大歌单/全专辑入队时按 100 个一批分块请求，避免 URL 过长被网关拒。
  Future<List<SongUrlInfo>> songUrls(List<int> ids,
      {String level = 'standard'}) async {
    if (ids.isEmpty) return const <SongUrlInfo>[];
    const int chunkSize = 100;
    final List<SongUrlInfo> out = <SongUrlInfo>[];
    for (int i = 0; i < ids.length; i += chunkSize) {
      final List<int> chunk =
          ids.sublist(i, (i + chunkSize).clamp(0, ids.length));
      final Map<String, Object?> res =
          await _api.get('/song/url/v1', <String, String>{
        'id': chunk.join(','),
        'level': level,
      });
      final Object? data = res['data'];
      if (data is! List<Object?>) continue;
      out.addAll(data
          .whereType<Map<String, Object?>>()
          .map(SongUrlInfo.fromJson)
          .toList(growable: false));
    }
    return out;
  }

  /// 歌词：一次请求拿 yrc（逐字）+ lrc + 翻译 + 音译
  Future<LyricData> lyric(int id) async {
    final Map<String, Object?> res =
        await _api.get('/lyric/new', <String, String>{'id': '$id'});
    final Object? yrc = res['yrc'];
    final Object? lrc = res['lrc'];
    final Object? tlyric = res['tlyric'];
    final Object? romalrc = res['romalrc'];
    return LyricData(
      yrcText: _lyricText(yrc),
      lrcText: _lyricText(lrc),
      translationText: _lyricText(tlyric),
      romanizationText: _lyricText(romalrc),
    );
  }

  /// 歌曲详情批量补全（搜索结果之外的 id 场景备用）
  Future<List<Song>> songDetails(List<int> ids) async {
    if (ids.isEmpty) return const <Song>[];
    final Map<String, Object?> res =
        await _api.get('/song/detail', <String, String>{'ids': ids.join(',')});
    return _songsFrom(res['songs']);
  }

  List<Song> _songsFrom(Object? raw) {
    if (raw is! List<Object?>) return const <Song>[];
    return raw
        .whereType<Map<String, Object?>>()
        .map(Song.fromCloudJson)
        .where((Song s) => s.id != 0)
        .toList(growable: false);
  }

  String? _lyricText(Object? node) {
    if (node is Map<String, Object?>) {
      final String? lyric = node['lyric'] as String?;
      if (lyric != null && lyric.isNotEmpty) return lyric;
    }
    return null;
  }
}
