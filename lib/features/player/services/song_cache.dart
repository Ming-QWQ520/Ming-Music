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

class SongCacheService {
  SongCacheService();

  /// 缓存目录名（位于 applicationSupport 下，系统清缓存不触碰）
  static const String _dirName = 'media_cache';

  /// 单文件下载并发上限（避免预加载+连播打满带宽）
  static const int _maxConcurrent = 2;

  /// 缓存总容量上限：超过后按最后使用时间从旧到新清理
  static const int _maxTotalBytes = 1536 * 1024 * 1024; // 1.5GB

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

  // ---------------------------------------------------------------- download

  /// 下载 [url] 到缓存（完成后可经 [cachedPathFor] 命中）。
  /// 返回 true = 已完整落盘；false = 失败/被并发限制跳过。
  Future<bool> download(int songId, String level, String url) async {
    if (url.isEmpty) return false;
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
      files.sort((_CacheMeta a, _CacheMeta b) =>
          a.lastUsedAt.compareTo(b.lastUsedAt));
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
