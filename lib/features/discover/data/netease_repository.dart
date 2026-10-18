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

  /// 搜索（对齐 Zephyr-Music：/search 为主，/cloudsearch 兜底 ——
  /// 增强版 API 的 cloudsearch 在部分关键词下返回异常结构导致搜索报错）。
  Future<List<Song>> search(String keywords, {int limit = 30}) async {
    final Map<String, String> params = <String, String>{
      'keywords': keywords,
      'limit': '$limit',
      'offset': '0',
      'type': '1',
    };
    try {
      final Map<String, Object?> res = await _api.get('/search', params);
      final Object? result = res['result'];
      final Object? songs =
          (result is Map<String, Object?>) ? result['songs'] : null;
      final List<Song> parsed = _songsFrom(songs);
      if (parsed.isNotEmpty) return parsed;
    } catch (_) {
      // 主接口抖动 → 走 cloudsearch 兜底
    }
    final Map<String, Object?> res = await _api.get('/cloudsearch', params);
    final Object? data = res['data'];
    final Object? songs = (data is Map<String, Object?>) ? data['songs'] : null;
    return _songsFrom(songs);
  }

  /// 搜索建议（/search/suggest，type=mobile 返回 allMatch）
  Future<SearchSuggest> searchSuggest(String keywords) async {
    final Map<String, Object?> res = await _api.get('/search/suggest',
        <String, String>{'keywords': keywords, 'type': 'mobile'});
    final Object? result = res['result'];
    if (result is! Map<String, Object?>) return const SearchSuggest();
    return SearchSuggest.fromJson(result);
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

  /// 听歌打卡（/scrobble）：登录后播放计次上报（对齐网易云听歌排行）
  Future<void> scrobble(int id, int sourceId, int timeSec) async {
    await _api.get('/scrobble', <String, String>{
      'id': '$id',
      'sourceid': '$sourceId',
      'time': '$timeSec',
    });
  }

  /// 歌曲详情批量补全（搜索结果之外的 id 场景备用）
  Future<List<Song>> songDetails(List<int> ids) async {
    if (ids.isEmpty) return const <Song>[];
    final Map<String, Object?> res =
        await _api.get('/song/detail', <String, String>{'ids': ids.join(',')});
    return _songsFrom(res['songs']);
  }

  // -------------------------------------------------- 相似歌曲 / 歌曲百科 / MV

  /// 相似歌曲（/simi/song → songs，旧版字段 artists/album/duration）
  Future<List<Song>> simiSongs(int id) async {
    final Map<String, Object?> res =
        await _api.get('/simi/song', <String, String>{'id': '$id'});
    return _songsFrom(res['songs']);
  }

  /// 歌曲百科（/song/wiki/summary）：曲风/推荐标签/获奖成就/影视节目/乐评
  Future<SongWikiSummary> songWiki(int id) async {
    final Map<String, Object?> res = await _api
        .get('/song/wiki/summary', <String, String>{'id': '$id'});
    final Map<String, Object?> payload = apiPayload(res);
    return SongWikiSummary.fromJson(payload);
  }

  /// MV 播放地址（/mv/url → data.url，r 为分辨率）
  Future<MvUrlInfo> mvUrl(int id) async {
    final Map<String, Object?> res =
        await _api.get('/mv/url', <String, String>{'id': '$id'});
    final Map<String, Object?> payload = apiPayload(res);
    return MvUrlInfo.fromJson(payload);
  }

  /// MV 详情（/mv/detail → data：标题/艺人/封面/时长/播放量）
  Future<MvDetail> mvDetail(int mvid) async {
    final Map<String, Object?> res =
        await _api.get('/mv/detail', <String, String>{'mvid': '$mvid'});
    final Map<String, Object?> payload = apiPayload(res);
    return MvDetail.fromJson(mvid, payload);
  }

  /// 艺人详情（/artist/detail → data：身份描述/作品规模）
  Future<ArtistDetailInfo> artistDetail(int id) async {
    final Map<String, Object?> res =
        await _api.get('/artist/detail', <String, String>{'id': '$id'});
    final Map<String, Object?> payload = apiPayload(res);
    return ArtistDetailInfo.fromJson(payload);
  }

  /// 艺人热门 50 首（/artist/top/song → songs）
  Future<List<Song>> artistTopSongs(int id) async {
    final Map<String, Object?> res =
        await _api.get('/artist/top/song', <String, String>{'id': '$id'});
    return _songsFrom(res['songs']);
  }

  /// 歌手名搜索 → 首位艺人 id（歌曲百科艺人卡定位用）
  Future<int?> artistIdByName(String name) async {
    final Map<String, Object?> res = await _api.get('/search', <String, String>{
      'keywords': name,
      'type': '100',
      'limit': '1',
    });
    final Object? result = res['result'];
    final Object? artists =
        result is Map<String, Object?> ? result['artists'] : null;
    if (artists is! List<Object?> || artists.isEmpty) return null;
    final Map<String, Object?> first =
        artists.first as Map<String, Object?>;
    return (first['id'] as num?)?.toInt();
  }

  /// 相似歌单（/simi/playlist → playlists，旧版字段 coverImgUrl）
  Future<List<PlaylistMeta>> simiPlaylists(int id) async {
    final Map<String, Object?> res =
        await _api.get('/simi/playlist', <String, String>{'id': '$id'});
    final Object? list = res['playlists'];
    if (list is! List<Object?>) return const <PlaylistMeta>[];
    return list
        .whereType<Map<String, Object?>>()
        .map(PlaylistMeta.fromJson)
        .where((PlaylistMeta p) => p.id != 0)
        .toList(growable: false);
  }

  // -------------------------------------------------- 歌单 CRUD / 收藏

  /// 新建歌单（/playlist/create）
  Future<int> playlistCreate(String name, {bool privacy = false}) async {
    final Map<String, Object?> res = await _api.get('/playlist/create',
        <String, String>{'name': name, 'privacy': privacy ? '10' : '0'});
    final int id = (res['id'] as num?)?.toInt() ?? 0;
    if (id == 0) throw ApiException('歌单创建失败');
    return id;
  }

  /// 删除歌单（/playlist/delete）
  Future<void> playlistDelete(int id) async {
    final Map<String, Object?> res =
        await _api.get('/playlist/delete', <String, String>{'id': '$id'});
    final Object? code = res['code'];
    if (code is int && code != 200) {
      throw ApiException('删除歌单失败（$code）');
    }
  }

  /// 收藏 / 取消收藏歌单（/playlist/subscribe，t=1 收藏 2 取消）
  Future<void> playlistSubscribe(int id, {required bool subscribe}) async {
    await _api.get('/playlist/subscribe',
        <String, String>{'id': '$id', 't': subscribe ? '1' : '2'});
  }

  /// 歌单增删歌曲（/playlist/tracks?op=add|del&pid=&tracks=）
  Future<void> playlistTracks({
    required int playlistId,
    required List<int> trackIds,
    required bool add,
  }) async {
    final Map<String, Object?> res = await _api.get('/playlist/tracks',
        <String, String>{
          'op': add ? 'add' : 'del',
          'pid': '$playlistId',
          'tracks': trackIds.join(','),
        });
    final Object? body = res['body'];
    // 部分版本返回 {body:{code:502,...}}：曲目已存在等场景给出明确错误
    if (body is Map<String, Object?>) {
      final Object? code = body['code'];
      if (code is int && code != 200) {
        throw ApiException(code == 502 ? '歌曲已在该歌单中' : '操作失败（$code）');
      }
    }
  }

  /// 收藏 / 取消收藏歌手（/artist/sub，t=1 收藏 0 取消）
  Future<void> artistSub(int id, {required bool subscribe}) async {
    await _api.get('/artist/sub',
        <String, String>{'id': '$id', 't': subscribe ? '1' : '0'});
  }

  // -------------------------------------------------- 听歌排行 / 最近播放

  /// 听歌排行（/user/record，type=0 所有时间 1 最近一周）
  Future<List<PlayRecordSong>> userRecord(int uid,
      {required bool week}) async {
    final Map<String, Object?> res = await _api.get('/user/record',
        <String, String>{'uid': '$uid', 'type': week ? '1' : '0'});
    final Map<String, Object?> payload = apiPayload(res);
    for (final String key in <String>['weekData', 'allData']) {
      final Object? list = payload[key];
      if (list is! List<Object?>) continue;
      return list
          .whereType<Map<String, Object?>>()
          .map(PlayRecordSong.fromRecordJson)
          .whereType<PlayRecordSong>()
          .toList(growable: false);
    }
    return const <PlayRecordSong>[];
  }

  /// 最近播放-歌曲（/record/recent/song）
  Future<List<PlayRecordSong>> recentSongs({int limit = 100}) async {
    final Map<String, Object?> res = await _api
        .get('/record/recent/song', <String, String>{'limit': '$limit'});
    final Map<String, Object?> payload = apiPayload(res);
    Object? list = payload['list'];
    if (list == null) {
      final Object? data = payload['data'];
      if (data is Map<String, Object?>) list = data['list'];
    }
    if (list is! List<Object?>) return const <PlayRecordSong>[];
    return list
        .whereType<Map<String, Object?>>()
        .map(PlayRecordSong.fromRecentJson)
        .whereType<PlayRecordSong>()
        .toList(growable: false);
  }

  // -------------------------------------------------- 音乐云盘

  /// 云盘列表（/user/cloud）
  Future<List<CloudSong>> cloudList({int limit = 100, int offset = 0}) async {
    final Map<String, Object?> res = await _api.get('/user/cloud',
        <String, String>{'limit': '$limit', 'offset': '$offset'});
    final Object? data = res['data'];
    if (data is! List<Object?>) return const <CloudSong>[];
    return data
        .whereType<Map<String, Object?>>()
        .map(CloudSong.fromJson)
        .whereType<CloudSong>()
        .toList(growable: false);
  }

  /// 删除云盘歌曲（/user/cloud/del）
  Future<void> cloudDelete(int id) async {
    final Map<String, Object?> res =
        await _api.get('/user/cloud/del', <String, String>{'id': '$id'});
    final Object? code = res['code'];
    if (code is int && code != 200) {
      throw ApiException('删除失败（$code）');
    }
  }

  // -------------------------------------------------- 专辑 / 心动漫游

  /// 专辑详情（/album）
  Future<AlbumDetail> albumDetail(int id) async {
    final Map<String, Object?> res =
        await _api.get('/album', <String, String>{'id': '$id'});
    if (res['album'] == null && res['code'] != 200) {
      throw ApiException('专辑不存在或已下架');
    }
    return AlbumDetail.fromJson(res);
  }

  /// 心动模式/智能播放（/playmode/intelligence/list）：登录后个性化推荐
  Future<List<Song>> intelligenceList(int songId, int playlistId) async {
    final Map<String, Object?> res =
        await _api.get('/playmode/intelligence/list', <String, String>{
      'songId': '$songId',
      'pid': '$playlistId',
      'limit': '30',
    });
    final Object? data = res['data'];
    if (data is! List<Object?>) return const <Song>[];
    final List<Song> out = <Song>[];
    for (final Object? item in data) {
      if (item is! Map<String, Object?>) continue;
      final Object? info = item['songInfo'];
      if (info is! Map<String, Object?>) continue;
      final Song s = Song.fromCloudJson(info);
      if (s.id != 0) out.add(s);
    }
    return out;
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
