/// 曲目领域模型。
///
/// 两种来源：
///  - 网易云在线曲目：neteaseId 非空，source（播放直链）在入队前经
///    /song/url/v1 统一解析（直链约 20 分钟过期，不落盘存储）；
///  - 收藏曲目：完整 Track 序列化到本地，播放时按 neteaseId 重新解析。
library;

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.source,
    this.cover,
    this.lyricsAsset,
    this.durationMs,
    this.isNetwork = false,
    this.isCustom = false,
    this.neteaseId,
    this.fee = 0,
  });

  final String id;

  /// 网易云歌曲 id（在线曲目非空）
  final int? neteaseId;

  final String title;
  final String artist;
  final String album;

  /// 播放源：网络直链（http(s)）；网易云曲目在入队前填充
  final String source;

  /// 封面：asset 全路径或网络 URL，null 使用占位
  final String? cover;

  /// LRC 歌词 asset 路径（本地曲目遗留字段）
  final String? lyricsAsset;

  final int? durationMs;
  final bool isNetwork;
  final bool isCustom;

  /// 付费标记：0 免费 / 1 VIP / 4 购买专辑 / 8 低音质免费
  final int fee;

  bool get isVipOnly => fee == 1;

  /// 是否需要解析播放直链（收藏恢复场景：有网易云 id 但无直链）
  bool get needsUrlResolve =>
      neteaseId != null && (source.isEmpty || !source.startsWith('http'));

  Track copyWith({
    String? title,
    String? artist,
    String? album,
    String? source,
    String? cover,
    int? durationMs,
  }) {
    return Track(
      id: id,
      neteaseId: neteaseId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      source: source ?? this.source,
      cover: cover ?? this.cover,
      lyricsAsset: lyricsAsset,
      durationMs: durationMs ?? this.durationMs,
      isNetwork: isNetwork,
      isCustom: isCustom,
      fee: fee,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'neteaseId': neteaseId,
        'title': title,
        'artist': artist,
        'album': album,
        'source': source,
        'cover': cover,
        'lyricsAsset': lyricsAsset,
        'durationMs': durationMs,
        'isNetwork': isNetwork,
        'isCustom': isCustom,
        'fee': fee,
      };

  factory Track.fromMap(Map<Object?, Object?> map) => Track(
        id: map['id'] as String,
        neteaseId: (map['neteaseId'] as num?)?.toInt(),
        title: map['title'] as String? ?? '未知歌曲',
        artist: map['artist'] as String? ?? '未知歌手',
        album: map['album'] as String? ?? '单曲',
        source: map['source'] as String? ?? '',
        cover: map['cover'] as String?,
        lyricsAsset: map['lyricsAsset'] as String?,
        durationMs: (map['durationMs'] as num?)?.toInt(),
        isNetwork: map['isNetwork'] as bool? ?? true,
        isCustom: map['isCustom'] as bool? ?? false,
        fee: (map['fee'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
