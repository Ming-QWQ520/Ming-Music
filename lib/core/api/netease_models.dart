/// 网易云领域模型：歌曲 / 歌单 / 播放地址 / 歌词。
///
/// 解析兼容两种字段命名：
///  - `/cloudsearch`：`ar[]`（歌手）、`al{}`（专辑）、`dt`（时长）
///  - `/search` 旧版：`artists[]`、`album{}`、`duration`
library;

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

  bool get isVipOnly => fee == 1;

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
    );
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
  });

  final int id;
  final String name;
  final String? coverUrl;
  final int? playCount;
  final int? trackCount;
  final String? creator;
  final String? description;

  static PlaylistMeta fromJson(Map<String, Object?> j) => PlaylistMeta(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? '歌单',
        coverUrl: _pickCover(j),
        playCount: (j['playCount'] as num?)?.toInt(),
        trackCount: (j['trackCount'] as num?)?.toInt() ??
            (j['trackIds'] as List<Object?>?)?.length,
        creator: _creatorName(j),
        description: j['description'] as String?,
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
}

/// 歌单详情（meta + 完整曲目）
class PlaylistDetail {
  const PlaylistDetail({required this.meta, required this.tracks});

  final PlaylistMeta meta;
  final List<Song> tracks;
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
  });

  final int id;
  final String url;
  final int? br;
  final String? type;
  final int fee;
  final bool isTrial;

  bool get playable => url.isNotEmpty;

  static SongUrlInfo fromJson(Map<String, Object?> j) => SongUrlInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        url: normalizeNeteaseUrl(j['url'] as String?),
        br: (j['br'] as num?)?.toInt(),
        type: j['type'] as String?,
        fee: (j['fee'] as num?)?.toInt() ?? 0,
        isTrial: j['freeTrialInfo'] != null,
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
  const HotWord({required this.word, this.iconUrl});

  final String word;
  final String? iconUrl;

  static HotWord fromJson(Map<String, Object?> j) => HotWord(
        word: (j['searchWord'] as String?) ?? '',
        iconUrl: normalizeNeteaseUrl(j['iconUrl'] as String?),
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
        artistName: (j['artistName'] as String?) ??
            _artistsNames(j['artists']),
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
    this.totalPlayCount = 0,
    this.totalPlayText = '',
  });

  /// 按主标题聚合的条目组（曲风、推荐标签、语种、BPM…）
  final List<WikiGroup> groups;

  /// 回忆坐标：首次聆听日期（musicFirstListenDto.date）
  final String firstListenDate;

  /// 回忆坐标：季节 · 时段（musicFirstListenDto.season / period）
  final String firstListenExtra;

  /// 回忆坐标：累计播放次数（musicTotalPlayDto.playCount，服务端真实统计）
  final int totalPlayCount;

  /// 回忆坐标：累计播放附加描述（musicTotalPlayDto.text）
  final String totalPlayText;

  bool get isEmpty => groups.isEmpty && totalPlayCount == 0 && firstListenDate.isEmpty;

  static SongWikiSummary fromJson(Map<String, Object?> data) {
    final Object? blocks = data['blocks'] ?? data['data'];
    if (blocks is! List<Object?>) return const SongWikiSummary();

    final List<WikiGroup> groups = <WikiGroup>[];
    String firstDate = '';
    String firstExtra = '';
    int totalPlay = 0;
    String totalText = '';

    // 按服务端 position 升序（对齐 Zephyr 的 sort）
    final List<Map<String, Object?>> sorted = blocks
        .whereType<Map<String, Object?>>()
        .toList()
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
            }
            final Object? tp = ext['musicTotalPlayDto'];
            if (tp is Map<String, Object?>) {
              totalPlay =
                  (tp['playCount'] is num ? (tp['playCount'] as num).toInt() : int.tryParse('${tp['playCount'] ?? ''}')) ?? totalPlay;
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
            (c['uiElement'] as Map<String, Object?>?) ?? const <String, Object?>{};
        final Map<String, Object?> mt =
            (ue['mainTitle'] as Map<String, Object?>?) ?? const <String, Object?>{};
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
                (r['uiElement'] as Map<String, Object?>?) ?? const <String, Object?>{};
            final Map<String, Object?> rmt =
                (rue['mainTitle'] as Map<String, Object?>?) ?? const <String, Object?>{};
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
