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
  });

  final int id;
  final String name;
  final String artists;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// fee: 0 免费 / 1 VIP / 4 购买专辑 / 8 低音质免费（非会员可听）
  final int fee;

  bool get isVipOnly => fee == 1;

  /// 转为播放队列条目：source 留空，播放前经 /song/url/v1 统一解析
  Track toTrack() => Track(
        id: 'netease_$id',
        neteaseId: id,
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
