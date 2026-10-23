/// 边听边缓存服务（需求：默认开启，并非下载）：
///
///  - 播放时把音频流后台落盘到应用私有目录（applicationSupport，
///    系统「清除缓存」不会删除该目录 —— 需求：无法在应用缓存中清理，
///    只能在设置中清理）；再次播放同一首（同音质）时直接命中本地文件，
///    秒开且不耗流量；
///  - 预加载下一首（需求：默认开启）：在当前曲目开播后预解析并预下载
///    队列下一首，切歌即命中缓存；关闭缓存但开启预加载时，退化为
///    临时 AudioPlayer 预热（提前建立连接与首段缓冲）；
///  - 单飞去重（同一首歌并发只下载一次）、.part 临时文件原子改名、
///    LRU 容量上限（默认 1.5GB，超限清理最久未用文件）；
///  - 仅缓存网易云在线曲目；本地/自定义直链不缓存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';

/// 单条缓存记录元信息（用于大小统计与 LRU）
class _CacheMeta {
  _CacheMeta({
    required this.path,
    required this.size,
    required this.lastUsedAt,
  });

  final String path;
  final int size;
  final DateTime lastUsedAt;
}

/// 缓存歌曲条目（缓存列表页展示用，需求：点击数据缓存可查看缓存的音乐）
class CacheEntry {
  const CacheEntry({
    required this.key,
    required this.songId,
    required this.level,
    required this.path,
    required this.sizeBytes,
    required this.cachedAt,
    this.title = '',
    this.artist = '',
    this.cover = '',
  });

  final String key;
  final int songId;
  final String level;
  final String path;
  final int sizeBytes;
  final DateTime cachedAt;

  /// 展示元信息（下载时随音频写入 meta.json；旧缓存无元信息时为空）
  final String title;
  final String artist;
  final String cover;

  /// 元信息缺失时以「歌曲 id」兕底显示
  String get displayTitle => title.isEmpty ? '歌曲 $songId' : title;
  String get displayArtist => artist.isEmpty ? '元信息未记录' : artist;
}

class SongCacheService {
  SongCacheService();

  /// 缓存目录名（位于 applicationSupport 下，系统清缓存不触碰）
  static const String _dirName = 'media_cache';

  /// 单文件下载并发上限（避免预加载+连播打满带宽）
  static const int _maxConcurrent = 2;

  /// 默认缓存总容量上限（需求：默认 3GB，可在缓存音乐页自行修改/关闭）
  static const int kDefaultMaxBytes = 3 * 1024 * 1024 * 1024; // 3GB

  /// LRU 容量上限（可变：需求「可在缓存音乐页面自行更改最大缓存，
  /// 也可关闭此功能」）；关闭缓存时本服务不再接收新下载。
  int _maxTotalBytes = kDefaultMaxBytes;

  int get maxTotalBytes => _maxTotalBytes;

  /// 更新容量上限（立即触发一次 LRU 收敛，超出部分从旧到新清理）
  void setMaxBytes(int bytes) {
    _maxTotalBytes = bytes <= 0 ? kDefaultMaxBytes : bytes;
    unawaited(_pruneIfNeeded());
  }

  final HttpClient _http = HttpClient()
    ..userAgent = 'MingMusic/1.1'
    ..connectionTimeout = const Duration(seconds: 15);

  Directory? _dir;
  Future<Directory>? _dirFuture;

  /// key = `songId_level`（如 `123456_lossless`），value = 下载任务（单飞去重）
  final Map<String, Future<bool>> _inflight = <String, Future<bool>>{};

  /// 最近一次预加载的歌曲 key，避免快速切歌时重复预热
  String? _lastPreloadKey;

  int _activeDownloads = 0;
  final List<Completer<void>> _queueWaiters = <Completer<void>>[];

  // ---------------------------------------------------------------- init

  Future<Directory> _ensureDir() {
    if (_dir != null) return Future<Directory>.value(_dir);
    return _dirFuture ??= () async {
      final Directory support = await getApplicationSupportDirectory();
      final Directory dir = Directory('${support.path}/$_dirName');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir;
      // 启动时后台做一次 LRU 容量收敛（失败静默）
      unawaited(_pruneIfNeeded());
      return dir;
    }();
  }

  String keyFor(int songId, String level) => '${songId}_$level';

  /// 缓存文件最终路径（.done 表示完整）
  String _donePath(Directory dir, String key) => '${dir.path}/$key.done';

  String _partPath(Directory dir, String key) => '${dir.path}/$key.part';

  String _metaPath(Directory dir) => '${dir.path}/meta.json';

  // ---------------------------------------------------------------- meta

  /// 读取全部条目元信息（key → 展示字段）；文件不存在/损坏返回空表
  Future<Map<String, Map<String, Object?>>> _readMeta(Directory dir) async {
    try {
      final File f = File(_metaPath(dir));
      if (!f.existsSync()) return const <String, Map<String, Object?>>{};
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const <String, Map<String, Object?>>{};
      }
      return decoded.map<String, Map<String, Object?>>((String k, Object? v) =>
          MapEntry<String, Map<String, Object?>>(
              k, v is Map<String, Object?> ? v : const <String, Object?>{}));
    } catch (_) {
      return const <String, Map<String, Object?>>{};
    }
  }

  Future<void> _writeMeta(
      Directory dir, Map<String, Map<String, Object?>> meta) async {
    try {
      final File f = File(_metaPath(dir));
      await f.writeAsString(jsonEncode(meta), flush: true);
    } catch (_) {
      // 元信息写失败不影响音频缓存
    }
  }

  /// 记录/更新一条缓存元信息（下载完成时调用）
  Future<void> saveEntryMeta(
    int songId,
    String level, {
    required String title,
    required String artist,
    required String cover,
  }) async {
    try {
      final Directory dir = await _ensureDir();
      final String key = keyFor(songId, level);
      final Map<String, Map<String, Object?>> meta = await _readMeta(dir);
      final Map<String, Object?> old = meta[key] ?? const <String, Object?>{};
      meta[key] = <String, Object?>{
        'id': songId,
        'level': level,
        'title': title,
        'artist': artist,
        'cover': cover,
        'at': (old['at'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      };
      await _writeMeta(dir, meta);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- query

  /// 命中返回本地文件绝对路径（可直接交给播放内核 file:// 播放）
  Future<String?> cachedPathFor(int songId, String level) async {
    try {
      final Directory dir = await _ensureDir();
      final File f = File(_donePath(dir, keyFor(songId, level)));
      if (!f.existsSync()) return null;
      // 触碰访问时间（LRU 依据）
      f.setLastModifiedSync(DateTime.now());
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// 缓存总占用（字节），设置页展示
  Future<int> totalSizeBytes() async {
    try {
      final Directory dir = await _ensureDir();
      int total = 0;
      await for (final FileSystemEntity e in dir.list()) {
        if (e is! File) continue;
        try {
          total += e.lengthSync();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空全部缓存（设置页「清理」入口；返回是否成功）
  Future<bool> clearAll() async {
    try {
      final Directory dir = await _ensureDir();
      await for (final FileSystemEntity e in dir.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
      _inflight.clear();
      _lastPreloadKey = null;
      return true;
    } catch (e) {
      debugPrint('SongCache.clearAll failed: $e');
      return false;
    }
  }

  /// 删除单条缓存（缓存列表页；返回是否成功）
  Future<bool> removeEntry(String key) async {
    try {
      final Directory dir = await _ensureDir();
      final File done = File(_donePath(dir, key));
      if (done.existsSync()) done.deleteSync();
      final File part = File(_partPath(dir, key));
      if (part.existsSync()) part.deleteSync();
      final Map<String, Map<String, Object?>> meta = await _readMeta(dir);
      if (meta.containsKey(key)) {
        meta.remove(key);
        await _writeMeta(dir, meta);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 已缓存音频的歌曲 id 集合（歌单页歌名缓存状态着色 / 离线可播判断）
  Future<Set<int>> cachedSongIds() async {
    final Set<int> ids = <int>{};
    try {
      final Directory dir = await _ensureDir();
      await for (final FileSystemEntity e in dir.list()) {
        final String name = e.path.split(Platform.pathSeparator).last;
        if (e is! File || !name.endsWith('.done')) continue;
        final int under = name.indexOf('_');
        if (under <= 0) continue;
        final int? id = int.tryParse(name.substring(0, under));
        if (id != null) ids.add(id);
      }
    } catch (_) {}
    return ids;
  }

  /// 缓存条目列表（缓存列表页；按缓存时间倒序）
  Future<List<CacheEntry>> listEntries() async {
    final List<CacheEntry> out = <CacheEntry>[];
    try {
      final Directory dir = await _ensureDir();
      final Map<String, Map<String, Object?>> meta = await _readMeta(dir);
      await for (final FileSystemEntity e in dir.list()) {
        if (e is! File) continue;
        final String name = e.path.split(Platform.pathSeparator).last;
        if (!name.endsWith('.done')) continue;
        final int under = name.indexOf('_');
        if (under <= 0) continue;
        final int? songId = int.tryParse(name.substring(0, under));
        final String level = name.substring(under + 1, name.length - 5);
        if (songId == null) continue;
        final Map<String, Object?> m = meta[name] ?? const <String, Object?>{};
        out.add(CacheEntry(
          key: name,
          songId: songId,
          level: level,
          path: e.path,
          sizeBytes: e.lengthSync(),
          cachedAt: DateTime.fromMillisecondsSinceEpoch(
              (m['at'] as num?)?.toInt() ??
                  e.lastModifiedSync().millisecondsSinceEpoch),
          title: (m['title'] as String?) ?? '',
          artist: (m['artist'] as String?) ?? '',
          cover: (m['cover'] as String?) ?? '',
        ));
      }
    } catch (_) {}
    out.sort((CacheEntry a, CacheEntry b) => b.cachedAt.compareTo(a.cachedAt));
    return out;
  }

  // ---------------------------------------------------------------- download

  /// 下载 [url] 到缓存（完成后可经 [cachedPathFor] 命中）。
  /// 返回 true = 已完整落盘；false = 失败/被并发限制跳过。
  Future<bool> download(int songId, String level, String url) async {
    if (url.isEmpty) return false;
    // 需求：缓存功能关闭时不写入新缓存（已缓存文件保留可播）
    if (!_enabled) return false;
    final String key = keyFor(songId, level);
    final Future<bool>? existing = _inflight[key];
    if (existing != null) return existing;

    final Future<bool> task = _downloadGuarded(key, url);
    _inflight[key] = task;
    try {
      return await task;
    } finally {
      _inflight.remove(key);
    }
  }

  /// 缓存功能总开关（需求：可关闭；关闭时不再新增缓存，
  /// 已缓存歌曲仍可离线播放）
  bool _enabled = true;

  bool get enabled => _enabled;

  void setEnabled(bool on) => _enabled = on;

  Future<bool> _downloadGuarded(String key, String url) async {
    await _acquireSlot();
    try {
      return await _downloadCore(key, url);
    } finally {
      _releaseSlot();
    }
  }

  Future<void> _acquireSlot() async {
    if (_activeDownloads < _maxConcurrent) {
      _activeDownloads++;
      return;
    }
    final Completer<void> c = Completer<void>();
    _queueWaiters.add(c);
    await c.future;
    // 被唤醒者接续持有槽位（_releaseSlot 只负责减计数并唤醒）
    _activeDownloads++;
  }

  void _releaseSlot() {
    _activeDownloads--;
    if (_activeDownloads < 0) _activeDownloads = 0;
    if (_queueWaiters.isNotEmpty) {
      final Completer<void> w = _queueWaiters.removeAt(0);
      w.complete();
    }
  }

  Future<bool> _downloadCore(String key, String url) async {
    Directory? dir;
    try {
      dir = await _ensureDir();
      final File done = File(_donePath(dir, key));
      if (done.existsSync()) return true; // 已缓存

      final File part = File(_partPath(dir, key));
      if (part.existsSync()) part.deleteSync();

      final HttpClientRequest req = await _http.getUrl(Uri.parse(url));
      final HttpClientResponse res = await req.close();
      if (res.statusCode != 200) {
        await res.listen(null).cancel();
        return false;
      }
      final IOSink sink = part.openWrite();
      try {
        await for (final List<int> chunk in res) {
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        await sink.close().catchError((Object _) {});
        if (part.existsSync()) part.deleteSync();
        return false;
      }
      // 完整性：size > 0 才认为有效
      if (part.lengthSync() <= 0) {
        part.deleteSync();
        return false;
      }
      part.renameSync(done.path);
      done.setLastModifiedSync(DateTime.now());
      unawaited(_pruneIfNeeded());
      return true;
    } catch (e) {
      debugPrint('SongCache download $key failed: $e');
      // 清理残留 .part
      try {
        if (dir != null) {
          final File part = File(_partPath(dir, key));
          if (part.existsSync()) part.deleteSync();
        }
      } catch (_) {}
      return false;
    }
  }

  /// LRU 容量收敛：超出上限时按最后修改时间从旧到新删除
  ///（上限可在缓存音乐页调整；需求默认 3GB）
  Future<void> _pruneIfNeeded() async {
    final Directory? dir = _dir;
    if (dir == null || !dir.existsSync()) return;
    try {
      final List<_CacheMeta> files = <_CacheMeta>[];
      int total = 0;
      await for (final FileSystemEntity e in dir.list()) {
        if (e is! File) continue;
        try {
          final FileStat st = e.statSync();
          if (st.type != FileSystemEntityType.file) continue;
          files.add(_CacheMeta(
            path: e.path,
            size: st.size,
            lastUsedAt: st.modified,
          ));
          total += st.size;
        } catch (_) {}
      }
      if (total <= _maxTotalBytes) return;
      files.sort(
          (_CacheMeta a, _CacheMeta b) => a.lastUsedAt.compareTo(b.lastUsedAt));
      for (final _CacheMeta m in files) {
        if (total <= _maxTotalBytes) break;
        try {
          File(m.path).deleteSync();
          total -= m.size;
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('SongCache prune failed: $e');
    }
  }

  /// 预加载预热（关闭缓存但开启预加载时）：临时播放器拉起连接与首段缓冲。
  /// 拿到 duration 即代表首段元数据与缓冲就绪，立即释放播放器。
  Future<void> warmUp(String url) async {
    ja.AudioPlayer? p;
    try {
      p = ja.AudioPlayer();
      await p.setUrl(url).timeout(const Duration(seconds: 8));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    } catch (_) {
      // 预热失败不影响主流程
    } finally {
      try {
        await p?.dispose();
      } catch (_) {}
    }
  }

  /// 预加载去重 key（PlayerNotifier 用）
  bool shouldPreload(String key) => _lastPreloadKey != key;

  void markPreloaded(String key) => _lastPreloadKey = key;

  void dispose() {
    _http.close();
  }
}
