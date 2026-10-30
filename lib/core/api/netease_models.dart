/// 网易云领域模型：歌曲 / 歌单 / 播放地址 / 歌词。
///
/// 解析兼容两种字段命名：
///  - `/cloudsearch`：`ar[]`（歌手）、`al{}`（专辑）、`dt`（时长）
///  - `/search` 旧版：`artists[]`、`album{}`、`duration`
library;

import 'dart:convert' show jsonDecode;

import 'netease_api.dart' show normalizeNeteaseUrl;
import '../../features/library/domain/track.dart';

/// 歌曲条目（搜索结果 / 歌单 / 榜单通用）
class Song {
  const Song({
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    this.coverUrl,
    this.durationMs,
    this.fee = 0,
    this.mvId,
    this.artistId,
    this.albumId,
  });

  final int id;
  final String name;
  final String artists;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// fee: 0 免费 / 1 VIP / 4 购买专辑 / 8 低音质免费（非会员可听）
  final int fee;

  /// MV id（song/detail 的 mv 字段，非零表示有 MV；/simi/song 旧版字段同名）
  final int? mvId;

  /// 首位艺人 id（长按菜单「歌手」跳转 /artist/:id 用）
  final int? artistId;

  /// 专辑 id（长按菜单「专辑」跳转 /album/:id 用）
  final int? albumId;

  bool get isVipOnly => fee == 1;

  /// 封面覆盖拷贝（搜索结果 /song/detail 批量补封面用）
  Song withCover(String? cover) => Song(
        id: id,
        name: name,
        artists: artists,
        album: album,
        coverUrl: cover,
        durationMs: durationMs,
        fee: fee,
        mvId: mvId,
        artistId: artistId,
        albumId: albumId,
      );

  /// 序列化（歌单详情离线缓存用）
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'artists': artists,
        'album': album,
        'coverUrl': coverUrl,
        'durationMs': durationMs,
        'fee': fee,
        'mvId': mvId,
        'artistId': artistId,
        'albumId': albumId,
      };

  static Song fromStoredJson(Map<String, Object?> j) => Song(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? '未知歌曲',
        artists: (j['artists'] as String?) ?? '未知歌手',
        album: (j['album'] as String?) ?? '',
        coverUrl: j['coverUrl'] as String?,
        durationMs: (j['durationMs'] as num?)?.toInt(),
        fee: (j['fee'] as num?)?.toInt() ?? 0,
        mvId: (j['mvId'] as num?)?.toInt(),
        artistId: (j['artistId'] as num?)?.toInt(),
        albumId: (j['albumId'] as num?)?.toInt(),
      );

  /// 转为播放队列条目：source 留空，播放前经 /song/url/v1 统一解析
  Track toTrack() => Track(
        id: 'netease_$id',
        neteaseId: id,
        mvId: mvId,
        title: name,
        artist: artists.isEmpty ? '未知歌手' : artists,
        album: album.isEmpty ? '单曲' : album,
        source: '',
        cover: coverUrl,
        durationMs: durationMs,
        isNetwork: true,
        isCustom: false,
        fee: fee,
        artistId: artistId,
        albumId: albumId,
      );

  static Song fromCloudJson(Map<String, Object?> j) {
    return Song(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: (j['name'] as String?) ?? '未知歌曲',
      artists: _joinArtists(j),
      album: _albumName(j),
      coverUrl: _coverUrl(j),
      durationMs:
          (j['dt'] as num?)?.toInt() ?? (j['duration'] as num?)?.toInt(),
      fee: (j['fee'] as num?)?.toInt() ?? 0,
      mvId: (j['mv'] as num?)?.toInt(),
      artistId: _firstArtistId(j),
      albumId: _albumId(j),
    );
  }

  static int? _firstArtistId(Map<String, Object?> j) {
    final List<Object?>? ar = (j['ar'] ?? j['artists']) as List<Object?>?;
    if (ar == null || ar.isEmpty) return null;
    final Object? first = ar.first;
    if (first is Map<String, Object?>) {
      return (first['id'] as num?)?.toInt();
    }
    return null;
  }

  static int? _albumId(Map<String, Object?> j) {
    final Object? al = j['al'] ?? j['album'];
    if (al is Map<String, Object?>) {
      return (al['id'] as num?)?.toInt();
    }
    return null;
  }

  static String _joinArtists(Map<String, Object?> j) {
    final List<Object?>? ar = (j['ar'] ?? j['artists']) as List<Object?>?;
    if (ar == null || ar.isEmpty) return '未知歌手';
    final List<String> names = <String>[];
    for (final Object? item in ar) {
      if (item is Map<String, Object?>) {
        final String? n = item['name'] as String?;
        if (n != null && n.isNotEmpty) names.add(n);
      }
    }
    return names.join(' / ');
  }

  static String _albumName(Map<String, Object?> j) {
    final Object? al = j['al'] ?? j['album'];
    if (al is Map<String, Object?>) {
      return (al['name'] as String?) ?? '单曲';
    }
    return '单曲';
  }

  static String? _coverUrl(Map<String, Object?> j) {
    final Object? al = j['al'] ?? j['album'];
    if (al is Map<String, Object?>) {
      final String? pic = al['picUrl'] as String?;
      if (pic != null && pic.isNotEmpty) return normalizeNeteaseUrl(pic);
    }
    final String? pic = j['picUrl'] as String?;
    return (pic != null && pic.isNotEmpty) ? normalizeNeteaseUrl(pic) : null;
  }
}

/// 歌单 / 榜单元信息
class PlaylistMeta {
  const PlaylistMeta({
    required this.id,
    required this.name,
    this.coverUrl,
    this.playCount,
    this.trackCount,
    this.creator,
    this.description,
    this.creatorUserId,
    this.subscribed,
    this.creatorAvatarUrl,
    this.commentCount,
  });

  final int id;
  final String name;
  final String? coverUrl;
  final int? playCount;
  final int? trackCount;
  final String? creator;
  final String? description;

  /// 歌单创建者用户 id（区分「我创建的」/「我收藏的」）
  final int? creatorUserId;

  /// 是否为收藏的歌单（/user/playlist 返回的 subscribed 字段）
  final bool? subscribed;

  /// 创作者头像（歌单详情页创作者行）
  final String? creatorAvatarUrl;

  /// 评论数（歌单详情动态字段）
  final int? commentCount;

  static PlaylistMeta fromJson(Map<String, Object?> j) => PlaylistMeta(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? '歌单',
        coverUrl: _pickCover(j),
        playCount: (j['playCount'] as num?)?.toInt(),
        trackCount: (j['trackCount'] as num?)?.toInt() ??
            (j['trackIds'] as List<Object?>?)?.length,
        creator: _creatorName(j),
        description: j['description'] as String?,
        creatorUserId: (j['userId'] as num?)?.toInt(),
        subscribed: j['subscribed'] as bool?,
        creatorAvatarUrl: normalizeNeteaseUrl(
          ((j['creator'] as Map<String, Object?>?)?['avatarUrl']) as String?,
        ),
        commentCount: (j['commentCount'] as num?)?.toInt(),
      );

  static String? _pickCover(Map<String, Object?> j) {
    for (final String key in <String>['coverImgUrl', 'picUrl']) {
      final Object? v = j[key];
      if (v is String && v.isNotEmpty) return normalizeNeteaseUrl(v);
    }
    return null;
  }

  static String? _creatorName(Map<String, Object?> j) {
    final Object? c = j['creator'];
    if (c is Map<String, Object?>) return c['nickname'] as String?;
    return null;
  }

  /// 序列化（歌单详情离线缓存用）
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'coverUrl': coverUrl,
        'playCount': playCount,
        'trackCount': trackCount,
        'creator': creator,
        'description': description,
        'creatorUserId': creatorUserId,
        'subscribed': subscribed,
        'creatorAvatarUrl': creatorAvatarUrl,
        'commentCount': commentCount,
      };

  static PlaylistMeta fromStoredJson(Map<String, Object?> j) => PlaylistMeta(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? '歌单',
        coverUrl: j['coverUrl'] as String?,
        playCount: (j['playCount'] as num?)?.toInt(),
        trackCount: (j['trackCount'] as num?)?.toInt(),
        creator: j['creator'] as String?,
        description: j['description'] as String?,
        creatorUserId: (j['creatorUserId'] as num?)?.toInt(),
        subscribed: j['subscribed'] as bool?,
        creatorAvatarUrl: j['creatorAvatarUrl'] as String?,
        commentCount: (j['commentCount'] as num?)?.toInt(),
      );
}

/// 歌单详情（meta + 完整曲目）
class PlaylistDetail {
  const PlaylistDetail({required this.meta, required this.tracks});

  final PlaylistMeta meta;
  final List<Song> tracks;

  /// 序列化（歌单详情离线缓存用：无网时也可打开歌单查看）
  Map<String, Object?> toJson() => <String, Object?>{
        'meta': meta.toJson(),
        'tracks': <Object?>[for (final Song s in tracks) s.toJson()],
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      };

  static PlaylistDetail fromStoredJson(Map<String, Object?> j) =>
      PlaylistDetail(
        meta: PlaylistMeta.fromStoredJson(
            (j['meta'] as Map<String, Object?>?) ?? const <String, Object?>{}),
        tracks: <Song>[
          for (final Object? t
              in (j['tracks'] as List<Object?>? ?? const <Object?>[]))
            if (t is Map<String, Object?>) Song.fromStoredJson(t),
        ],
      );
}

/// /song/url/v1 单条结果
class SongUrlInfo {
  const SongUrlInfo({
    required this.id,
    required this.url,
    this.br,
    this.type,
    this.fee = 0,
    this.isTrial = false,
    this.level,
    this.sr,
  });

  final int id;
  final String url;
  final int? br;
  final String? type;
  final int fee;
  final bool isTrial;

  /// 实际下发的音质档位（level 字段：请求档位因权限回落时与请求值不同，
  /// 如未登录请求 lossless 实际返回 exhigh）—— 播放设置「音质」项展示
  /// 「真实品质」的数据源
  final String? level;

  /// 实际采样率（sr 字段，Hz，如 44100/48000/96000）—— 展示「真实频率」
  final int? sr;

  bool get playable => url.isNotEmpty;

  static SongUrlInfo fromJson(Map<String, Object?> j) => SongUrlInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        url: normalizeNeteaseUrl(j['url'] as String?),
        br: (j['br'] as num?)?.toInt(),
        type: j['type'] as String?,
        fee: (j['fee'] as num?)?.toInt() ?? 0,
        isTrial: j['freeTrialInfo'] != null,
        level: j['level'] as String?,
        sr: (j['sr'] as num?)?.toInt(),
      );
}

/// 歌词数据：优先逐字（yrc），否则逐行 LRC + 可选翻译/音译
class LyricData {
  const LyricData({
    this.yrcText,
    this.lrcText,
    this.translationText,
    this.romanizationText,
  });

  /// 逐字歌词原文（yrc 格式）
  final String? yrcText;

  /// 常规 LRC
  final String? lrcText;

  /// 翻译歌词（LRC 格式，与 lrcText 时间轴对应）
  final String? translationText;

  /// 音译歌词（romalrc，粤语/日语拼音，无翻译时展示，仿网易云）
  final String? romanizationText;

  bool get hasYrc => yrcText != null && yrcText!.trim().isNotEmpty;
  bool get hasLrc => lrcText != null && lrcText!.trim().isNotEmpty;
  bool get isEmpty => !hasYrc && !hasLrc;
}

/// 热搜词（/search/hot/detail）
class HotWord {
  const HotWord({required this.word, this.iconUrl, this.score = 0, this.iconType = 0});

  final String word;
  final String? iconUrl;

  /// 热度值（/search/hot/detail 的 score，仅排序参考）
  final double score;

  /// 官方图标类型：1 = 上升（搜索页榜单行的红色 ↑ 箭头），0 = 无
  final int iconType;

  static HotWord fromJson(Map<String, Object?> j) => HotWord(
        word: (j['searchWord'] as String?) ?? '',
        iconUrl: normalizeNeteaseUrl(j['iconUrl'] as String?),
        score: (j['score'] as num?)?.toDouble() ?? 0,
        iconType: (j['iconType'] as num?)?.toInt() ?? 0,
      );
}

/// MV 详情（/mv/detail → data）：标题/艺人/封面/时长/播放量，
/// 配合 /mv/url 直链构成 MV 播放闭环。
class MvDetail {
  const MvDetail({
    required this.id,
    required this.name,
    required this.artistName,
    required this.durationMs,
    required this.playCount,
    this.coverUrl,
  });

  final int id;
  final String name;
  final String artistName;
  final int durationMs;
  final int playCount;
  final String? coverUrl;

  static MvDetail fromJson(int id, Map<String, Object?> j) => MvDetail(
        id: (j['id'] as num?)?.toInt() ?? id,
        name: (j['name'] as String?) ?? 'MV',
        artistName: (j['artistName'] as String?) ?? _artistsNames(j['artists']),
        durationMs: (j['duration'] as num?)?.toInt() ?? 0,
        playCount: (j['playCount'] as num?)?.toInt() ?? 0,
        coverUrl: normalizeNeteaseUrl(j['cover'] as String?),
      );

  static String _artistsNames(Object? raw) {
    if (raw is! List<Object?>) return '';
    final List<String> names = <String>[];
    for (final Object? item in raw) {
      if (item is Map<String, Object?>) {
        final String? n = item['name'] as String?;
        if (n != null && n.isNotEmpty) names.add(n);
      }
    }
    return names.join(' / ');
  }
}

/// /mv/url 单条结果
class MvUrlInfo {
  const MvUrlInfo({required this.id, required this.url, this.r});

  final int id;
  final String url;
  final int? r;

  static MvUrlInfo fromJson(Map<String, Object?> j) => MvUrlInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        url: normalizeNeteaseUrl(j['url'] as String?),
        r: (j['r'] as num?)?.toInt(),
      );
}

/// 艺人详情（/artist/detail → data）：身份描述 + 作品/专辑/MV 数量。
/// 实测 api-enhanced 该接口不含粉丝数字段，粉丝数以作品规模卡片呈现。
class ArtistDetailInfo {
  const ArtistDetailInfo({
    required this.id,
    required this.name,
    required this.identityDesc,
    required this.musicSize,
    required this.albumSize,
    required this.mvSize,
    this.coverUrl,
    this.alias = const <String>[],
  });

  final int id;
  final String name;
  final String identityDesc;
  final int musicSize;
  final int albumSize;
  final int mvSize;
  final String? coverUrl;
  final List<String> alias;

  static ArtistDetailInfo fromJson(Map<String, Object?> d) {
    final Map<String, Object?> artist =
        (d['artist'] as Map<String, Object?>?) ?? const <String, Object?>{};
    final Map<String, Object?> identify =
        (d['identify'] as Map<String, Object?>?) ?? const <String, Object?>{};
    final List<String> alias = <String>[];
    final Object? rawAlias = artist['alias'];
    if (rawAlias is List<Object?>) {
      for (final Object? item in rawAlias) {
        if (item is Map<String, Object?>) {
          final String? n = item['name'] as String?;
          if (n != null && n.isNotEmpty) alias.add(n);
        } else if (item is String && item.isNotEmpty) {
          alias.add(item);
        }
      }
    }
    return ArtistDetailInfo(
      id: (artist['id'] as num?)?.toInt() ?? 0,
      name: (artist['name'] as String?) ?? '未知艺人',
      identityDesc: (identify['imageDesc'] as String?) ?? '',
      musicSize: (artist['musicSize'] as num?)?.toInt() ?? 0,
      albumSize: (artist['albumSize'] as num?)?.toInt() ?? 0,
      mvSize: (artist['mvSize'] as num?)?.toInt() ?? 0,
      coverUrl: normalizeNeteaseUrl(artist['cover'] as String?),
      alias: alias,
    );
  }
}

/// 歌曲百科（/song/wiki/summary → data.blocks，对齐 Zephyr NpWikiSummary.vue）：
///  - 回忆坐标块 MUSIC_MEMORY_MULTI_TWO_GRID：服务端首次聆听日期 + 累计播放次数；
///  - 音乐百科块 SONG_PLAY_ABOUT_TAB_SONG_BASIC（旧版兼容 SONG_PLAY_ABOUT_SONG_BASIC）：
///    曲风 / 推荐标签 / 语种 / BPM / 乐谱（textLinks + resources 双源提取）；
///  - 相似歌曲 / 相关歌单由专用接口另行拉取（保持原实现）。
class SongWikiSummary {
  const SongWikiSummary({
    this.groups = const <WikiGroup>[],
    this.firstListenDate = '',
    this.firstListenExtra = '',
    this.firstListenDesc = '',
    this.totalPlayCount = 0,
    this.totalPlayText = '',
  });

  /// 按主标题聚合的条目组（曲风、推荐标签、语种、BPM…）
  final List<WikiGroup> groups;

  /// 回忆坐标：首次聆听日期（musicFirstListenDto.date）
  final String firstListenDate;

  /// 回忆坐标：季节 · 时段（musicFirstListenDto.season / period）
  final String firstListenExtra;

  /// 回忆坐标：首次聆听补充描述（musicFirstListenDto.desc，需求「显示补全」）
  final String firstListenDesc;

  /// 回忆坐标：累计播放次数（musicTotalPlayDto.playCount，服务端真实统计）
  final int totalPlayCount;

  /// 回忆坐标：累计播放附加描述（musicTotalPlayDto.text）
  final String totalPlayText;

  bool get isEmpty =>
      groups.isEmpty &&
      totalPlayCount == 0 &&
      firstListenDate.isEmpty &&
      firstListenDesc.isEmpty;

  static SongWikiSummary fromJson(Map<String, Object?> data) {
    final Object? blocks = data['blocks'] ?? data['data'];
    if (blocks is! List<Object?>) return const SongWikiSummary();

    final List<WikiGroup> groups = <WikiGroup>[];
    String firstDate = '';
    String firstExtra = '';
    String firstDesc = '';
    int totalPlay = 0;
    String totalText = '';

    // 按服务端 position 升序（对齐 Zephyr 的 sort）
    final List<Map<String, Object?>> sorted =
        blocks.whereType<Map<String, Object?>>().toList()
          ..sort((Map<String, Object?> a, Map<String, Object?> b) {
            final int pa = int.tryParse('${a['position'] ?? 0}') ?? 0;
            final int pb = int.tryParse('${b['position'] ?? 0}') ?? 0;
            return pa.compareTo(pb);
          });

    for (final Map<String, Object?> block in sorted) {
      final String code = '${block['showType'] ?? block['code'] ?? ''}';
      final Object? creatives = block['creatives'];
      if (creatives is! List<Object?>) continue;

      // ---- 回忆坐标：首次聆听 + 累计播放（服务端数据）
      if (code == 'MUSIC_MEMORY_MULTI_TWO_GRID') {
        for (final Object? c in creatives) {
          if (c is! Map<String, Object?>) continue;
          final Object? resources = c['resources'];
          if (resources is! List<Object?>) continue;
          for (final Object? r in resources) {
            if (r is! Map<String, Object?>) continue;
            final Object? ext = r['resourceExt'];
            if (ext is! Map<String, Object?>) continue;
            final Object? fl = ext['musicFirstListenDto'];
            if (fl is Map<String, Object?>) {
              firstDate = (fl['date'] as String?) ?? firstDate;
              final String season = (fl['season'] as String?) ?? '';
              final String period = (fl['period'] as String?) ?? '';
              firstExtra = <String>[
                if (season.isNotEmpty) season,
                if (period.isNotEmpty) period,
              ].join(' · ');
              firstDesc = (fl['desc'] as String?) ?? firstDesc;
            }
            final Object? tp = ext['musicTotalPlayDto'];
            if (tp is Map<String, Object?>) {
              totalPlay = (tp['playCount'] is num
                      ? (tp['playCount'] as num).toInt()
                      : int.tryParse('${tp['playCount'] ?? ''}')) ??
                  totalPlay;
              totalText = (tp['text'] as String?) ?? totalText;
            }
          }
        }
        continue;
      }

      // ---- 音乐百科：新版 TAB 块 + 旧版块双兼容
      if (code != 'SONG_PLAY_ABOUT_TAB_SONG_BASIC' &&
          code != 'SONG_PLAY_ABOUT_SONG_BASIC') {
        continue;
      }
      for (final Object? c in creatives) {
        if (c is! Map<String, Object?>) continue;
        final Map<String, Object?> ue =
            (c['uiElement'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        final Map<String, Object?> mt =
            (ue['mainTitle'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        final String title = (mt['title'] as String?) ?? '';
        if (title.isEmpty) continue;
        final List<String> items = <String>[];
        // ① textLinks（语种 / BPM / 乐谱等纯文本项，旧实现遗漏导致信息不全）
        final Object? textLinks = ue['textLinks'];
        if (textLinks is List<Object?>) {
          for (final Object? tl in textLinks) {
            if (tl is! Map<String, Object?>) continue;
            final String? t = tl['text'] as String?;
            if (t != null && t.isNotEmpty) items.add(t);
          }
        }
        // ② resources（曲风 / 推荐标签等资源项）
        final Object? resources = c['resources'];
        if (resources is List<Object?>) {
          for (final Object? r in resources) {
            if (r is! Map<String, Object?>) continue;
            final Map<String, Object?> rue =
                (r['uiElement'] as Map<String, Object?>?) ??
                    const <String, Object?>{};
            final Map<String, Object?> rmt =
                (rue['mainTitle'] as Map<String, Object?>?) ??
                    const <String, Object?>{};
            final String? t = rmt['title'] as String?;
            if (t != null && t.isNotEmpty) items.add(t);
          }
        }
        if (items.isNotEmpty) groups.add(WikiGroup(title: title, items: items));
      }
    }
    return SongWikiSummary(
      groups: groups,
      firstListenDate: firstDate,
      firstListenExtra: firstExtra,
      firstListenDesc: firstDesc,
      totalPlayCount: totalPlay,
      totalPlayText: totalText,
    );
  }
}

/// 百科条目组（例：曲风 → [摇滚-流行摇滚, 流行]）
class WikiGroup {
  const WikiGroup({required this.title, required this.items});

  final String title;
  final List<String> items;
}

// ---------------------------------------------------------------- 听歌排行 / 最近播放 / 云盘 / 专辑

/// 听歌排行 / 最近播放条目（/user/record、/record/recent/song）
class PlayRecordSong {
  const PlayRecordSong({
    required this.song,
    this.score = 0,
    this.playAt,
  });

  /// 歌曲体（/user/record 为 {song:{...}, playCount}；/record/recent 为
  /// {data:{list:[{data:{...歌曲体}, playTime}]}} 双层 data 包裹）
  final Song song;

  /// 播放次数（听歌排行的计分）
  final int score;

  /// 最近播放时间（毫秒时间戳，/record/recent/song）
  final int? playAt;

  static Song? _songOf(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Song s = Song.fromCloudJson(raw);
    return s.id == 0 ? null : s;
  }

  /// /user/record 列表项
  static PlayRecordSong? fromRecordJson(Map<String, Object?> j) {
    final Song? s = _songOf(j['song']);
    if (s == null) return null;
    return PlayRecordSong(
      song: s,
      score: (j['playCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// /record/recent/song 列表项
  static PlayRecordSong? fromRecentJson(Map<String, Object?> j) {
    final Song? s = _songOf(j['data'] ?? j['song']);
    if (s == null) return null;
    return PlayRecordSong(
      song: s,
      playAt: (j['playTime'] as num?)?.toInt(),
      score: (j['playCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 音乐云盘歌曲（/user/cloud → data[].simpleSong）
class CloudSong {
  const CloudSong({
    required this.song,
    this.fileSize = 0,
    this.fileName = '',
  });

  final Song song;

  /// 文件大小（字节）
  final int fileSize;

  /// 云盘文件名
  final String fileName;

  bool get isVip => song.isVipOnly;

  static CloudSong? fromJson(Map<String, Object?> j) {
    final Map<String, Object?>? simple =
        j['simpleSong'] as Map<String, Object?>?;
    final Map<String, Object?>? songNode = j['song'] as Map<String, Object?>?;
    final Song? s = simple != null
        ? Song.fromCloudJson(simple)
        : (songNode != null ? Song.fromCloudJson(songNode) : null);
    if (s == null || s.id == 0) return null;
    final String name =
        (j['fileName'] as String?) ?? (j['songName'] as String?) ?? s.name;
    return CloudSong(
      song: s,
      fileSize: (j['fileSize'] as num?)?.toInt() ?? 0,
      fileName: name,
    );
  }
}

/// 音乐云盘容量信息（/user/cloud 顶层字段）
class CloudDriveInfo {
  const CloudDriveInfo({
    this.count = 0,
    this.size = 0,
    this.maxSize = 0,
  });

  /// 云盘歌曲总数（分页无关的顶层 count）
  final int count;

  /// 已用容量（字节）
  final int size;

  /// 云盘总容量（字节，60GB 级别按账号等级不同）
  final int maxSize;

  static CloudDriveInfo fromJson(Map<String, Object?> j) => CloudDriveInfo(
        count: (j['count'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt() ?? 0,
        maxSize: (j['maxSize'] as num?)?.toInt() ?? 0,
      );
}

/// 专辑详情（/album）
class AlbumDetail {
  const AlbumDetail({required this.meta, required this.tracks});

  final PlaylistMeta meta;
  final List<Song> tracks;

  static AlbumDetail fromJson(Map<String, Object?> j) {
    final Map<String, Object?> album =
        (j['album'] as Map<String, Object?>?) ?? j;
    final PlaylistMeta meta = PlaylistMeta(
      id: (album['id'] as num?)?.toInt() ?? 0,
      name: (album['name'] as String?) ?? '专辑',
      coverUrl: normalizeNeteaseUrl(album['picUrl'] as String?),
      trackCount: (album['size'] as num?)?.toInt(),
      description: j['description'] is String
          ? j['description'] as String
          : (album['description'] as String?),
      creator: _artistNames(album['artists'] ?? album['artist']),
    );
    return AlbumDetail(
      meta: meta,
      tracks: (j['songs'] as List<Object?>? ?? const <Object?>[])
          .whereType<Map<String, Object?>>()
          .map(Song.fromCloudJson)
          .where((Song s) => s.id != 0)
          .toList(growable: false),
    );
  }

  static String? _artistNames(Object? raw) {
    if (raw is! List<Object?>) return null;
    final List<String> names = <String>[];
    for (final Object? item in raw) {
      if (item is Map<String, Object?>) {
        final String? n = item['name'] as String?;
        if (n != null && n.isNotEmpty) names.add(n);
      }
    }
    return names.isEmpty ? null : names.join(' / ');
  }
}

/// 搜索建议（/search/suggest → result）
class SearchSuggest {
  const SearchSuggest({
    this.keywords = const <String>[],
    this.artists = const <String>[],
    this.albums = const <String>[],
  });

  final List<String> keywords;
  final List<String> artists;
  final List<String> albums;

  bool get isEmpty => keywords.isEmpty && artists.isEmpty && albums.isEmpty;

  static SearchSuggest fromJson(Map<String, Object?> result) {
    List<String> names(Object? raw) {
      if (raw is! List<Object?>) return const <String>[];
      final List<String> out = <String>[];
      for (final Object? item in raw) {
        if (item is Map<String, Object?>) {
          final String? n = item['name'] as String?;
          if (n != null && n.isNotEmpty) out.add(n);
        }
      }
      return out;
    }

    return SearchSuggest(
      keywords: names(result['allMatch']),
      artists: names(result['artists'] ?? result['artist']),
      albums: names(result['albums'] ?? result['album']),
    );
  }
}

// ---------------------------------------------------------------- 搜索联想词
//
// 第十七批需求：搜索联想词接口（官方 POST /search/suggest/keyword/get，
// 参数 keyword 传 s 会返回 HTTP 400 空体）。响应结构（与官方 App 截图
// 逐字段对齐）：
//   data.suggests[]：第 0 条为直 hit 歌曲卡（resourceType == 'entity_card'，
//   含整首歌曲数据 relatedResource.baseInfo.simpleSongData）；其后为联想词
//   列表（keyword + tag「原唱/热搜」+ highLightInfo 高亮分段）；
//   data.recTitle = 「相关搜索」、data.recs[] 为相关搜索推荐。

/// 高亮分段：highLighted 为 true 的分段在联想下拉中着品牌红（官方 App 的
/// 「红色前缀」即由此渲染）
class SuggestSegment {
  const SuggestSegment({required this.text, required this.highlighted});

  final String text;
  final bool highlighted;

  static SuggestSegment fromJson(Map<String, Object?> j) => SuggestSegment(
        text: (j['text'] as String?) ?? '',
        highlighted: j['highLighted'] == true,
      );
}

/// 单条联想词
class SuggestWord {
  const SuggestWord({
    required this.keyword,
    this.segments = const <SuggestSegment>[],
    this.tag,
    this.directHit,
  });

  /// 完整词（点击即搜索该词）
  final String keyword;

  /// 高亮分段（空则整词无高亮渲染）
  final List<SuggestSegment> segments;

  /// 标签：「原唱」「热搜」或 null
  final String? tag;

  /// 直 hit 歌曲（仅第 0 条 entity_card 有：点击直接播放而非搜索）
  final Song? directHit;

  bool get isDirectHit => directHit != null;

  static SuggestWord fromJson(Map<String, Object?> j) {
    SuggestSegment seg(Map<String, Object?> s) => SuggestSegment.fromJson(s);
    List<SuggestSegment> parseSegments(Object? raw) {
      // highLightInfo 为「JSON 字符串」（服务端序列化数组），需二次解码
      List<Object?>? list;
      if (raw is String && raw.isNotEmpty) {
        try {
          final Object? decoded = jsonDecode(raw);
          if (decoded is List<Object?>) list = decoded;
        } catch (_) {
          // 脏分段 → 整词无高亮
        }
      } else if (raw is List<Object?>) {
        list = raw;
      }
      if (list == null) return const <SuggestSegment>[];
      final List<SuggestSegment> out = <SuggestSegment>[];
      for (final Object? item in list) {
        if (item is Map<String, Object?>) {
          final SuggestSegment s = seg(item);
          if (s.text.isNotEmpty) out.add(s);
        }
      }
      return out;
    }

    // 直 hit 歌曲：relatedResource.baseInfo.simpleSongData（标准 song 结构，
    // 复用 Song.fromCloudJson 解析 ar/al/dt 字段）
    Song? hit;
    if (j['resourceType'] == 'entity_card') {
      final Object? related = j['relatedResource'];
      final Object? baseInfo =
          related is Map<String, Object?> ? related['baseInfo'] : null;
      final Object? simple =
          baseInfo is Map<String, Object?> ? baseInfo['simpleSongData'] : null;
      if (simple is Map<String, Object?>) {
        final Song s = Song.fromCloudJson(simple);
        if (s.id != 0) hit = s;
      }
    }
    return SuggestWord(
      keyword: (j['keyword'] as String?) ?? '',
      segments: parseSegments(j['highLightInfo']),
      tag: j['tag'] is String && (j['tag'] as String).isNotEmpty
          ? j['tag'] as String
          : null,
      directHit: hit,
    );
  }
}

/// 搜索联想词聚合（搜索框下拉整包数据）
class KeywordSuggest {
  const KeywordSuggest({
    this.directHit,
    this.words = const <SuggestWord>[],
    this.recTitle = '相关搜索',
    this.recs = const <String>[],
  });

  /// 第 0 条直 hit 歌曲卡（可为空：老接口兜底时没有）
  final SuggestWord? directHit;

  /// 联想词列表（含「热搜」标签词条）
  final List<SuggestWord> words;

  /// 相关搜索标题（官方 data.recTitle）
  final String recTitle;

  /// 相关搜索词
  final List<String> recs;

  bool get isEmpty =>
      directHit == null && words.isEmpty && recs.isEmpty;
}

// ---------------------------------------------------------------- 搜索分类结果
//
// 第十四批需求：搜索对齐 Zephyr-Music WIP 分支 —— /search 的 type 全量
// 支持（1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1002 用户 / 1004 MV /
// 1006 歌词 / 1018 综合）。以下为各分类的轻量展示模型（仅搜索页使用）。

/// 专辑搜索结果（/search type=10 → result.albums[]）
class SearchAlbum {
  const SearchAlbum({
    required this.id,
    required this.name,
    required this.artist,
    this.picUrl,
    this.songCount,
    this.publishTime,
  });

  final int id;
  final String name;
  final String artist;
  final String? picUrl;
  final int? songCount;
  final int? publishTime;

  static SearchAlbum fromJson(Map<String, Object?> j) {
    final Object? artist = j['artist'];
    return SearchAlbum(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: (j['name'] as String?) ?? '未知专辑',
      artist: artist is Map<String, Object?>
          ? ((artist['name'] as String?) ?? '未知歌手')
          : '未知歌手',
      picUrl: _picOf(j['picUrl'] as String? ?? j['pic'] as String?),
      songCount: (j['size'] as num?)?.toInt(),
      publishTime: (j['publishTime'] as num?)?.toInt(),
    );
  }

  static String? _picOf(String? raw) =>
      (raw == null || raw.isEmpty) ? null : normalizeNeteaseUrl(raw);
}

/// 歌手搜索结果（/search type=100 → result.artists[]）
class SearchArtist {
  const SearchArtist({
    required this.id,
    required this.name,
    this.picUrl,
    this.alias = '',
    this.albumSize,
    this.musicSize,
    this.mvSize,
  });

  final int id;
  final String name;
  final String? picUrl;

  /// 别名（多个以「 / 」连接，如 Jay Chou / 周董）
  final String alias;
  final int? albumSize;
  final int? musicSize;
  final int? mvSize;

  static SearchArtist fromJson(Map<String, Object?> j) {
    final List<String> alias = <String>[];
    final Object? raw = j['alias'];
    if (raw is List<Object?>) {
      for (final Object? item in raw) {
        if (item is String && item.isNotEmpty) alias.add(item);
        if (item is Map<String, Object?>) {
          final String? n = item['name'] as String?;
          if (n != null && n.isNotEmpty) alias.add(n);
        }
      }
    }
    return SearchArtist(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: (j['name'] as String?) ?? '未知歌手',
      picUrl: SearchAlbum._picOf(
          j['picUrl'] as String? ?? j['img1v1Url'] as String?),
      alias: alias.isEmpty ? '' : alias.join(' / '),
      albumSize: (j['albumSize'] as num?)?.toInt(),
      musicSize: (j['musicSize'] as num?)?.toInt(),
      mvSize: (j['mvSize'] as num?)?.toInt(),
    );
  }
}

/// 用户搜索结果（/search type=1002 → result.userprofiles[]）
class SearchUser {
  const SearchUser({
    required this.userId,
    required this.nickname,
    this.avatarUrl,
    this.signature = '',
  });

  final int userId;
  final String nickname;
  final String? avatarUrl;
  final String signature;

  static SearchUser fromJson(Map<String, Object?> j) => SearchUser(
        userId:
            (j['userId'] as num?)?.toInt() ?? (j['id'] as num?)?.toInt() ?? 0,
        nickname: (j['nickname'] as String?) ?? '未知用户',
        avatarUrl: SearchAlbum._picOf(j['avatarUrl'] as String?),
        signature: (j['signature'] as String?) ?? '',
      );
}

/// MV 搜索结果（/search type=1004 → result.mvs[]）
class SearchMv {
  const SearchMv({
    required this.id,
    required this.name,
    required this.artistName,
    this.coverUrl,
    this.durationMs,
    this.playCount,
  });

  final int id;
  final String name;
  final String artistName;
  final String? coverUrl;
  final int? durationMs;
  final int? playCount;

  static SearchMv fromJson(Map<String, Object?> j) => SearchMv(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? 'MV',
        artistName: (j['artistName'] as String?) ?? '',
        coverUrl: SearchAlbum._picOf(j['cover'] as String?),
        durationMs: (j['duration'] as num?)?.toInt(),
        playCount: (j['playCount'] as num?)?.toInt(),
      );
}

/// 分类搜索聚合结果（repository.searchByType 产物；type 对应的列表非空，
/// 其余为空 —— 综合搜索时 order 决定展示顺序、多列表并存）
class SearchResults {
  const SearchResults({
    required this.type,
    this.songs = const <Song>[],
    this.playlists = const <PlaylistMeta>[],
    this.albums = const <SearchAlbum>[],
    this.artists = const <SearchArtist>[],
    this.users = const <SearchUser>[],
    this.mvs = const <SearchMv>[],
    this.order = const <String>[],
  });

  final int type;
  final List<Song> songs;
  final List<PlaylistMeta> playlists;
  final List<SearchAlbum> albums;
  final List<SearchArtist> artists;
  final List<SearchUser> users;
  final List<SearchMv> mvs;

  /// 综合搜索（1018）的区块顺序（'song' / 'playList' / 'artist' /
  /// 'album' / 'mv' / 'user' / 'sim_query'...，仅展示已知区块）
  final List<String> order;

  bool get isEmpty =>
      songs.isEmpty &&
      playlists.isEmpty &&
      albums.isEmpty &&
      artists.isEmpty &&
      users.isEmpty &&
      mvs.isEmpty;
}
