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

/// 榜单入口（官方固定 id，已按 /toplist 实测校准）：
/// 需求（搜索页热榜矩阵 + 发现页榜单精选自定义）：
/// 搜索页顺序 = 热搜榜 + 以下 12 个；发现页默认勾选前 6 个。
const List<ToplistConf> kToplists = <ToplistConf>[
  ToplistConf(id: 3778678, name: '热歌榜', color: 0xFFDF468B),
  ToplistConf(id: 2809513713, name: '欧美热歌榜', color: 0xFF2E7CF6),
  ToplistConf(id: 5059642708, name: '古风榜', color: 0xFF8F5BDB),
  ToplistConf(id: 19723756, name: '飙升榜', color: 0xFFE2483D),
  ToplistConf(id: 745956260, name: '韩语榜', color: 0xFF17B8A6),
  ToplistConf(id: 3779629, name: '新歌榜', color: 0xFFEB7524),
  ToplistConf(id: 991319590, name: '说唱榜', color: 0xFF6D4AFF),
  ToplistConf(id: 2884035, name: '原创榜', color: 0xFFB252B8),
  ToplistConf(id: 5059661515, name: '民谣榜', color: 0xFFC08B1D),
  ToplistConf(id: 5059644681, name: '日语榜', color: 0xFFE0559C),
  ToplistConf(id: 71385702, name: 'ACG 榜', color: 0xFF27AE60),
  ToplistConf(id: 5059633707, name: '摇滚榜', color: 0xFF607D8B),
];

class NeteaseRepository {
  NeteaseRepository(this._api);

  final NeteaseApi _api;

  /// 搜索（对齐 Zephyr-Music：/search 为主，/cloudsearch 兜底 ——
  /// 增强版 API 的 cloudsearch 在部分关键词下返回异常结构导致搜索报错）。
  /// 需求「搜索页显示每首歌的封面」：旧版 /search 结果的 album 只含
  /// picId 不含 picUrl —— 封面全灭；对封面缺失的结果批量 /song/detail
  /// 补全 al.picUrl（一次请求，与网易云客户端行为一致）。
  Future<List<Song>> search(String keywords, {int limit = 30}) async {
    final Map<String, String> params = <String, String>{
      'keywords': keywords,
      'limit': '$limit',
      'offset': '0',
      'type': '1',
    };
    List<Song> parsed = const <Song>[];
    try {
      final Map<String, Object?> res = await _api.get('/search', params);
      final Object? result = res['result'];
      final Object? songs =
          (result is Map<String, Object?>) ? result['songs'] : null;
      parsed = _songsFrom(songs);
    } catch (_) {
      // 主接口抖动 → 走 cloudsearch 兜底
    }
    if (parsed.isEmpty) {
      final Map<String, Object?> res = await _api.get('/cloudsearch', params);
      final Object? data = res['data'];
      final Object? songs =
          (data is Map<String, Object?>) ? data['songs'] : null;
      parsed = _songsFrom(songs);
    }
    return _fillMissingCovers(parsed);
  }

  /// 分类搜索（第十四批需求：对齐 Zephyr-Music WIP —— /search type 全量：
  /// 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1002 用户 / 1004 MV /
  /// 1006 歌词 / 1018 综合）。单曲沿用 search() 的 cloudsearch 兜底，
  /// 其余分类直接解析对应键；综合(1018)按 result.order 还原区块顺序。
  Future<SearchResults> searchByType(
    String keywords,
    int type, {
    int limit = 30,
  }) async {
    final Map<String, String> params = <String, String>{
      'keywords': keywords,
      'limit': '$limit',
      'offset': '0',
      'type': '$type',
    };

    // 单曲 / 歌词：复用既有解析（老字段 artists/album）+ 封面补全
    if (type == 1 || type == 1006) {
      final List<Song> songs = type == 1
          ? await search(keywords, limit: limit)
          : await _searchRawSongs(params);
      return SearchResults(type: type, songs: songs);
    }

    final Map<String, Object?> res = await _api.get('/search', params);
    final Object? result = res['result'];
    if (result is! Map<String, Object?>) {
      return SearchResults(type: type);
    }

    switch (type) {
      case 10: // 专辑
        return SearchResults(type: type, albums: _albumsFrom(result['albums']));
      case 100: // 歌手
        return SearchResults(
            type: type, artists: _artistsFrom(result['artists']));
      case 1000: // 歌单
        return SearchResults(
            type: type, playlists: _playlistsFrom(result['playlists']));
      case 1002: // 用户（键名 userprofiles）
        return SearchResults(
            type: type, users: _usersFrom(result['userprofiles']));
      case 1004: // MV
        return SearchResults(type: type, mvs: _mvsFrom(result['mvs']));
      case 1018: // 综合：order + 各区块
        final List<String> order = <String>[
          if (result['order'] is List<Object?>)
            for (final Object? o in result['order'] as List<Object?>)
              if (o is String) o,
        ];
        Map<String, Object?> section(String key) =>
            (result[key] as Map<String, Object?>?) ?? const <String, Object?>{};
        return SearchResults(
          type: type,
          order: order,
          songs: _songsFrom(section('song')['songs']),
          playlists: _playlistsFrom(section('playList')['playLists']),
          artists: _artistsFrom(section('artist')['artists']),
          albums: _albumsFrom(section('album')['albums']),
          users: _usersFrom(section('user')['users']),
          mvs: _mvsFrom(section('mv')['mvs']),
        );
      default:
        return SearchResults(type: type);
    }
  }

  /// /search 单次解析（无 cloudsearch 兜底，歌词分类专用）
  Future<List<Song>> _searchRawSongs(Map<String, String> params) async {
    final Map<String, Object?> res = await _api.get('/search', params);
    final Object? result = res['result'];
    final Object? songs =
        (result is Map<String, Object?>) ? result['songs'] : null;
    return _fillMissingCovers(_songsFrom(songs));
  }

  List<SearchAlbum> _albumsFrom(Object? raw) {
    if (raw is! List<Object?>) return const <SearchAlbum>[];
    return raw
        .whereType<Map<String, Object?>>()
        .map(SearchAlbum.fromJson)
        .where((SearchAlbum a) => a.id != 0)
        .toList(growable: false);
  }

  List<SearchArtist> _artistsFrom(Object? raw) {
    if (raw is! List<Object?>) return const <SearchArtist>[];
    return raw
        .whereType<Map<String, Object?>>()
        .map(SearchArtist.fromJson)
        .where((SearchArtist a) => a.id != 0)
        .toList(growable: false);
  }

  List<PlaylistMeta> _playlistsFrom(Object? raw) {
    if (raw is! List<Object?>) return const <PlaylistMeta>[];
    return raw
        .whereType<Map<String, Object?>>()
        .map(PlaylistMeta.fromJson)
        .where((PlaylistMeta p) => p.id != 0)
        .toList(growable: false);
  }

  List<SearchUser> _usersFrom(Object? raw) {
    if (raw is! List<Object?>) return const <SearchUser>[];
    return raw
        .whereType<Map<String, Object?>>()
        .map(SearchUser.fromJson)
        .where((SearchUser u) => u.userId != 0)
        .toList(growable: false);
  }

  List<SearchMv> _mvsFrom(Object? raw) {
    if (raw is! List<Object?>) return const <SearchMv>[];
    return raw
        .whereType<Map<String, Object?>>()
        .map(SearchMv.fromJson)
        .where((SearchMv m) => m.id != 0)
        .toList(growable: false);
  }

  /// 封面缺失批量补全：对 coverUrl 为空的歌请求 /song/detail（
  /// 响应含 al.picUrl），按 id 回填；失败静默返回原列表。
  Future<List<Song>> _fillMissingCovers(List<Song> songs) async {
    final List<int> missing = <int>[
      for (final Song s in songs)
        if ((s.coverUrl == null || s.coverUrl!.isEmpty) && s.id > 0) s.id,
    ];
    if (missing.isEmpty) return songs;
    try {
      final Map<int, String> covers = <int, String>{};
      for (int i = 0; i < missing.length; i += 100) {
        final List<int> chunk =
            missing.sublist(i, (i + 100).clamp(0, missing.length));
        final List<Song> filled = await songDetails(chunk);
        for (final Song f in filled) {
          if (f.coverUrl != null && f.coverUrl!.isNotEmpty) {
            covers[f.id] = f.coverUrl!;
          }
        }
      }
      if (covers.isEmpty) return songs;
      return <Song>[
        for (final Song s in songs) s.withCover(covers[s.id] ?? s.coverUrl),
      ];
    } catch (_) {
      return songs;
    }
  }

  /// 搜索建议（/search/suggest，type=mobile 返回 allMatch）。
  /// 作为联想词新接口三层兜底的最后一层。
  Future<SearchSuggest> searchSuggest(String keywords) async {
    final Map<String, Object?> res = await _api.get('/search/suggest',
        <String, String>{'keywords': keywords, 'type': 'mobile'});
    final Object? result = res['result'];
    if (result is! Map<String, Object?>) return const SearchSuggest();
    return SearchSuggest.fromJson(result);
  }

  /// 联想词主接口可用性进程内记忆：
  /// true = /search/suggest/mobile 可用，后续按键直达；false = 本进程降级旧接口。
  static bool _suggestWrapperOk = true;

  /// 搜索联想词（需求修复：上一版误用 POST /play/suggest，服务端实际
  /// 部署的接口按文档《搜索联想词（App 移动端版）》为
  /// GET /search/suggest/mobile，query 参数名必须是 keyword —— 传
  /// keywords/s 会返回 HTTP 400 空体）。
  ///
  /// 响应为官方联想接口 JSON：code + data.suggests，第 0 条直 hit 歌曲
  /// 卡（simpleSongData 全量字段）、其后联想词列表（首条"热搜"标签、
  /// 另有"原唱"标签），每条带 highLightInfo 高亮分段 —— 与现有
  /// KeywordSuggest/SuggestWord 模型字段完全对齐。
  ///
  /// 降级层保留旧 /search/suggest（type=mobile，无直 hit 卡与高亮，
  /// 功能不缺席）。
  Future<KeywordSuggest> searchKeywordSuggest(String keyword) async {
    final String kw = keyword.trim();
    if (kw.isEmpty) return const KeywordSuggest();
    // 主接口（失败形态：未部署 404 / 400 空体 / 网络异常 → 降级）
    if (_suggestWrapperOk) {
      try {
        return _parseKeywordSuggest(await _api.get(
          '/search/suggest/mobile',
          <String, String>{'keyword': kw},
        ));
      } catch (_) {
        _suggestWrapperOk = false; // 本进程降级，后续按键不再试错
      }
    }
    // 降级：旧联想接口（明文 GET，匿名可用）
    final SearchSuggest legacy = await searchSuggest(kw);
    return KeywordSuggest(
      words: <SuggestWord>[
        for (final String w in legacy.keywords)
          SuggestWord(keyword: w),
      ],
    );
  }

  static KeywordSuggest _parseKeywordSuggest(Map<String, Object?> res) {
    final Object? data = res['data'];
    if (data is! Map<String, Object?>) return const KeywordSuggest();
    final Object? suggests = data['suggests'];
    final List<SuggestWord> words = <SuggestWord>[];
    SuggestWord? directHit;
    if (suggests is List<Object?>) {
      for (final Object? item in suggests) {
        if (item is! Map<String, Object?>) continue;
        final SuggestWord w = SuggestWord.fromJson(item);
        if (w.keyword.isEmpty && !w.isDirectHit) continue;
        if (w.isDirectHit && directHit == null) {
          directHit = w; // 第 0 条直 hit 歌曲卡
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

  // ---------------------------------------------- 发现页（Zephyr 首页对齐）

  /// 推荐新音乐（/personalized/newsong → result[]，每项 {song:{...}}）
  Future<List<Song>> personalizedNewSongs({int limit = 12}) async {
    final Map<String, Object?> res = await _api
        .get('/personalized/newsong', <String, String>{'limit': '$limit'});
    final Object? result = res['result'];
    if (result is! List<Object?>) return const <Song>[];
    final List<Song> out = <Song>[];
    for (final Object? item in result) {
      if (item is! Map<String, Object?>) continue;
      final Object? song = item['song'];
      if (song is! Map<String, Object?>) continue;
      final Song s = Song.fromCloudJson(song);
      if (s.id != 0) out.add(s);
    }
    return out;
  }

  /// 新歌速递（/top/song → data[]；type: 0全部 7华语 96欧美 8日本 16韩国）
  Future<List<Song>> topSongs({int type = 0, int limit = 30}) async {
    final Map<String, Object?> res = await _api
        .get('/top/song', <String, String>{'type': '$type', 'limit': '$limit'});
    final Object? data = res['data'];
    if (data is! List<Object?>) return const <Song>[];
    return data
        .whereType<Map<String, Object?>>()
        .map(Song.fromCloudJson)
        .where((Song s) => s.id != 0)
        .toList(growable: false);
  }

  /// 每日推荐歌曲（/recommend/songs → data.dailySongs，需登录）
  Future<List<Song>> recommendSongs() async {
    final Map<String, Object?> res =
        await _api.get('/recommend/songs', const <String, String>{});
    final Object? data = res['data'];
    final Object? songs =
        (data is Map<String, Object?>) ? data['dailySongs'] : null;
    return _songsFrom(songs);
  }

  /// 私人漫游/私人 FM（/personal_fm → data[]，需登录）
  Future<List<Song>> personalFm() async {
    final Map<String, Object?> res =
        await _api.get('/personal_fm', const <String, String>{});
    return _songsFrom(res['data']);
  }

  /// 每日推荐歌单（/recommend/resource → recommend[]，需登录；
  /// 发现页「雷达歌单」入口数据源）
  Future<List<PlaylistMeta>> recommendPlaylists() async {
    final Map<String, Object?> res =
        await _api.get('/recommend/resource', const <String, String>{});
    final Object? recommend = res['recommend'];
    if (recommend is! List<Object?>) return const <PlaylistMeta>[];
    return recommend
        .whereType<Map<String, Object?>>()
        .map(PlaylistMeta.fromJson)
        .where((PlaylistMeta p) => p.id != 0)
        .toList(growable: false);
  }

  /// 榜单预览（/playlist/track/all，轻量只取前 N 行 —— 发现页榜单卡片
  /// 与搜索页热榜列用；不触发全量 trackIds 补全请求）
  Future<List<Song>> toplistPreview(int id, {int limit = 10}) async {
    final Map<String, Object?> res = await _api.get('/playlist/track/all',
        <String, String>{'id': '$id', 'limit': '$limit', 'offset': '0'});
    return _songsFrom(res['songs']);
  }

  /// 歌单轻量元数据（需求：发现页顶部个性化入口显示歌单封面 ——
  /// 只取 /playlist/detail 的 meta（封面/名称/曲目数），**不触发**
  /// trackIds 全量补全，避免为一张封面拉整个歌单）。
  Future<PlaylistMeta> playlistMetaLite(int id) async {
    final Map<String, Object?> res =
        await _api.get('/playlist/detail', <String, String>{'id': '$id'});
    final Object? playlist = res['playlist'];
    if (playlist is! Map<String, Object?>) {
      throw ApiException('歌单不存在或已下架');
    }
    return PlaylistMeta.fromJson(playlist);
  }

  /// 歌单详情（榜单同构，亦复用此接口）。
  /// 需求修复：/playlist/detail 的 tracks 只返回前 8 条 —— 大歌单列表
  /// 残缺且搜索加入的歌（不在前 8）无封面；按 trackIds 批量
  /// /song/detail 补全全量曲目（含 al.picUrl）。
  Future<PlaylistDetail> playlistDetail(int id) async {
    final Map<String, Object?> res =
        await _api.get('/playlist/detail', <String, String>{'id': '$id'});
    final Object? playlist = res['playlist'];
    if (playlist is! Map<String, Object?>) {
      throw ApiException('歌单不存在或已下架');
    }
    final PlaylistMeta meta = PlaylistMeta.fromJson(playlist);
    List<Song> tracks = _songsFrom(playlist['tracks']);
    final List<int> trackIds = <int>[
      for (final Object? t
          in (playlist['trackIds'] as List<Object?>? ?? const <Object?>[]))
        if (t is Map<String, Object?>) ((t['id'] as num?)?.toInt() ?? 0),
    ].where((int v) => v > 0).toList(growable: false);

    if (tracks.isEmpty && trackIds.isNotEmpty) {
      // tracks 全缺：仅 trackIds —— 分批拉全量
      tracks = await _songsByIds(trackIds);
    } else if (tracks.length < trackIds.length) {
      // tracks 只有前 N 条：补全剩余（保持 trackIds 顺序）
      final Set<int> have = <int>{for (final Song s in tracks) s.id};
      final List<int> rest = <int>[
        for (final int tid in trackIds)
          if (!have.contains(tid)) tid,
      ];
      if (rest.isNotEmpty) {
        final List<Song> more = await _songsByIds(rest);
        if (more.isNotEmpty) {
          final Map<int, Song> byId = <int, Song>{
            for (final Song s in more) s.id: s
          };
          final List<Song> merged = <Song>[...tracks];
          for (final int tid in trackIds) {
            if (!have.contains(tid) && byId.containsKey(tid)) {
              merged.add(byId[tid]!);
            }
          }
          tracks = merged;
        }
      }
    }
    return PlaylistDetail(meta: meta, tracks: tracks);
  }

  /// 按 id 批量拉歌曲（/song/detail，100 一批），带封面补全
  Future<List<Song>> _songsByIds(List<int> ids) async {
    final List<Song> out = <Song>[];
    for (int i = 0; i < ids.length; i += 100) {
      final List<int> chunk = ids.sublist(i, (i + 100).clamp(0, ids.length));
      try {
        final List<Song> part = await songDetails(chunk);
        out.addAll(part);
      } catch (_) {
        // 单批失败不阻断整体
      }
    }
    return out;
  }

  /// 榜单详情（同歌单接口）
  Future<PlaylistDetail> toplist(int id) => playlistDetail(id);

  /// 批量解析播放地址（/song/url/v1 支持逗号分隔多 id）。
  /// 大歌单/全专辑入队时按 100 个一批分块请求，避免 URL 过长被网关拒。
  /// 需求（songurl.txt）：杜比全景声需要 cookie 传入 os=pc 才能返回
  /// 正常码率的 url，其余档位不加（与文档约定一致）。
  Future<List<SongUrlInfo>> songUrls(List<int> ids,
      {String level = 'standard'}) async {
    if (ids.isEmpty) return const <SongUrlInfo>[];
    const int chunkSize = 100;
    final List<SongUrlInfo> out = <SongUrlInfo>[];
    final Map<String, String>? cookieKv =
        level == 'dolby' ? <String, String>{'os': 'pc'} : null;
    for (int i = 0; i < ids.length; i += chunkSize) {
      final List<int> chunk =
          ids.sublist(i, (i + chunkSize).clamp(0, ids.length));
      final Map<String, Object?> res = await _api.get('/song/url/v1', <String, String>{
        'id': chunk.join(','),
        'level': level,
      }, cookieKv: cookieKv);
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

  /// 高潮点（副歌时间，/song/chorus）—— Zephyr-Music 获取/解析方式：
  /// 返回 chorus[] 与 data[]（结构相同），每项含 startTime/endTime（毫秒）；
  /// 取首个 startTime 即歌曲高潮点（进度条白点 + 点击跳转）。
  /// 无数据返回 null（部分歌曲无副歌标注）。
  Future<int?> chorusStartMs(int id) async {
    final Map<String, Object?> res =
        await _api.get('/song/chorus', <String, String>{'id': '$id'});
    final Object? raw = res['chorus'] ?? res['data'];
    if (raw is! List<Object?> || raw.isEmpty) return null;
    for (final Object? item in raw) {
      if (item is! Map<String, Object?>) continue;
      final Object? start = item['startTime'];
      if (start is num && start >= 0) return start.round();
    }
    return null;
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
    final Map<String, Object?> res =
        await _api.get('/song/wiki/summary', <String, String>{'id': '$id'});
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
    final Map<String, Object?> first = artists.first as Map<String, Object?>;
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
    final Map<String, Object?> res =
        await _api.get('/playlist/tracks', <String, String>{
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
  Future<List<PlayRecordSong>> userRecord(int uid, {required bool week}) async {
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

  /// 云盘容量信息（/user/cloud 顶层 count/size/maxSize，分页无关）
  /// 需求：云盘显示总歌曲数和总容量；我的页登录后显示总歌曲数
  Future<CloudDriveInfo> cloudInfo() async {
    final Map<String, Object?> res = await _api
        .get('/user/cloud', <String, String>{'limit': '1', 'offset': '0'});
    return CloudDriveInfo.fromJson(res);
  }

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

  /// 上传本地音乐到云盘（需求：音乐云盘增加上传本地音乐功能）。
  /// 走 /cloud（multipart songFile），需登录 cookie；失败抛 ApiException。
  Future<void> cloudUpload(String filePath, String fileName) async {
    await _api.uploadCloudFile(filePath: filePath, fileName: fileName);
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
