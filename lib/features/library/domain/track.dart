/// 曲目领域模型。
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
  });

  final String id;
  final String title;
  final String artist;
  final String album;

  /// 播放源：
  ///  - 本地资源为相对 assets 根目录的路径，如 `audio/track_1.mp3`
  ///  - 网络曲目为 http(s) 直链
  final String source;

  /// 封面：asset 全路径或网络 URL，null 使用占位
  final String? cover;

  /// LRC 歌词 asset 路径，null 表示纯音乐
  final String? lyricsAsset;

  final int? durationMs;
  final bool isNetwork;
  final bool isCustom;

  Track copyWith({
    String? title,
    String? artist,
    String? album,
    String? cover,
  }) {
    return Track(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      source: source,
      cover: cover ?? this.cover,
      lyricsAsset: lyricsAsset,
      durationMs: durationMs,
      isNetwork: isNetwork,
      isCustom: isCustom,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'source': source,
        'cover': cover,
        'lyricsAsset': lyricsAsset,
        'durationMs': durationMs,
        'isNetwork': isNetwork,
        'isCustom': isCustom,
      };

  factory Track.fromMap(Map<Object?, Object?> map) => Track(
        id: map['id'] as String,
        title: map['title'] as String,
        artist: map['artist'] as String? ?? '未知歌手',
        album: map['album'] as String? ?? '单曲',
        source: map['source'] as String,
        cover: map['cover'] as String?,
        lyricsAsset: map['lyricsAsset'] as String?,
        durationMs: map['durationMs'] as int?,
        isNetwork: map['isNetwork'] as bool? ?? true,
        isCustom: map['isCustom'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 内置演示曲目（资源为本地合成的原创占位音频，可替换为真实音乐）。
const List<Track> kBuiltinTracks = <Track>[
  Track(
    id: 'builtin_1',
    title: '月色缓流',
    artist: '夜航星',
    album: '液态之夜',
    source: 'audio/track_1.mp3',
    cover: 'assets/covers/cover_1.png',
    lyricsAsset: 'assets/lyrics/track_1.lrc',
    durationMs: 42000,
  ),
  Track(
    id: 'builtin_2',
    title: '玻璃海',
    artist: '夜航星',
    album: '液态之夜',
    source: 'audio/track_2.mp3',
    cover: 'assets/covers/cover_2.png',
    lyricsAsset: 'assets/lyrics/track_2.lrc',
    durationMs: 48000,
  ),
  Track(
    id: 'builtin_3',
    title: '晚风信笺',
    artist: '森屿',
    album: '微光集',
    source: 'audio/track_3.mp3',
    cover: 'assets/covers/cover_3.png',
    lyricsAsset: 'assets/lyrics/track_3.lrc',
    durationMs: 45000,
  ),
  Track(
    id: 'builtin_4',
    title: '星轨漫步',
    artist: '森屿',
    album: '微光集',
    source: 'audio/track_4.mp3',
    cover: 'assets/covers/cover_4.png',
    durationMs: 51000,
  ),
];
