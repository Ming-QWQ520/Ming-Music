/// 播放队列持久化 + 历史快照 + 本机播放统计。
///
/// 职责（对应需求）：
///  - 播放列表持久化：队列/下标/来源名/循环模式落盘，重启恢复（不自动播放，
///    播放时经 needsUrlResolve 自动重解析直链）；
///  - 历史列表（最多 3 个）：每次装载新队列时把旧队列快照推入历史，
///    播放列表弹窗内可查看/恢复；
///  - 本机播放统计：歌曲播放计次，供歌曲百科「总听次数」展示（服务端无
///    公开播放次数接口，用本机统计闭环）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/prefs_keys.dart';
import '../../library/domain/track.dart';

/// 队列历史快照
@immutable
class QueueSnapshot {
  const QueueSnapshot({
    required this.title,
    required this.tracks,
    required this.savedAt,
  });

  final String title;
  final List<Track> tracks;
  final DateTime savedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        'title': title,
        'tracks': tracks.map((Track t) => t.toMap()).toList(),
        'savedAt': savedAt.millisecondsSinceEpoch,
      };

  static QueueSnapshot fromMap(Map<Object?, Object?> map) {
    final Object? raw = map['tracks'];
    final List<Track> tracks = raw is List<Object?>
        ? raw
            .whereType<Map<Object?, Object?>>()
            .map(Track.fromMap)
            .toList(growable: false)
        : const <Track>[];
    final int ms = (map['savedAt'] as num?)?.toInt() ?? 0;
    return QueueSnapshot(
      title: (map['title'] as String?) ?? '播放列表',
      tracks: tracks,
      savedAt: DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  /// 与另一快照内容等价（标题与曲目 id 序列一致）——去重用
  bool sameContent(String otherTitle, List<Track> other) {
    if (title != otherTitle || tracks.length != other.length) return false;
    for (int i = 0; i < tracks.length; i++) {
      if (tracks[i].id != other[i].id) return false;
    }
    return true;
  }
}

class QueuePersistence {
  QueuePersistence(this._prefs);

  final SharedPreferences _prefs;

  // ------------------------------------------------------------ 当前队列

  /// 保存当前队列状态（节流由调用方控制）
  Future<void> saveQueueState(
    List<Track> queue,
    int index,
    String? queueTitle,
  ) async {
    try {
      final String json = jsonEncode(<String, Object?>{
        'queue': queue.map((Track t) => t.toMap()).toList(),
        'index': index,
        'queueTitle': queueTitle,
      });
      await _prefs.setString(PrefsKeys.queueState, json);
    } catch (e) {
      debugPrint('saveQueueState failed: $e');
    }
  }

  /// 恢复队列状态；无存档返回 null
  ({List<Track> queue, int index, String? queueTitle})? loadQueueState() {
    final String? json = _prefs.getString(PrefsKeys.queueState);
    if (json == null || json.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) return null;
      final Object? raw = decoded['queue'];
      final List<Track> tracks = raw is List<Object?>
          ? raw
              .whereType<Map<String, Object?>>()
              .map(Track.fromMap)
              .toList(growable: false)
          : const <Track>[];
      if (tracks.isEmpty) return null;
      final int index =
          ((decoded['index'] as num?)?.toInt() ?? 0).clamp(0, tracks.length - 1);
      return (
        queue: tracks,
        index: index,
        queueTitle: decoded['queueTitle'] as String?,
      );
    } catch (e) {
      debugPrint('loadQueueState failed: $e');
      return null;
    }
  }

  Future<void> clearQueueState() => _prefs.remove(PrefsKeys.queueState);

  // ------------------------------------------------------------ 历史快照

  List<QueueSnapshot> loadHistory() {
    final String? json = _prefs.getString(PrefsKeys.queueHistory);
    if (json == null || json.isEmpty) return const <QueueSnapshot>[];
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is! List<Object?>) return const <QueueSnapshot>[];
      return decoded
          .whereType<Map<String, Object?>>()
          .map(QueueSnapshot.fromMap)
          .toList(growable: false);
    } catch (e) {
      debugPrint('loadHistory failed: $e');
      return const <QueueSnapshot>[];
    }
  }

  /// 推入历史快照（去重、最多保留 [maxHistory] 个，最新在前）
  Future<List<QueueSnapshot>> pushHistory(
    String title,
    List<Track> tracks, {
    int maxHistory = 3,
  }) async {
    if (tracks.isEmpty) return loadHistory();
    final List<QueueSnapshot> current = List<QueueSnapshot>.of(loadHistory())
      ..removeWhere((QueueSnapshot s) => s.sameContent(title, tracks));
    current.insert(0, QueueSnapshot(
      title: title,
      tracks: tracks,
      savedAt: DateTime.now(),
    ));
    while (current.length > maxHistory) {
      current.removeLast();
    }
    await _writeHistory(current);
    return current;
  }

  Future<List<QueueSnapshot>> removeAt(int index) async {
    final List<QueueSnapshot> current = List<QueueSnapshot>.of(loadHistory());
    if (index >= 0 && index < current.length) current.removeAt(index);
    await _writeHistory(current);
    return current;
  }

  Future<void> _writeHistory(List<QueueSnapshot> snapshots) async {
    try {
      final String json = jsonEncode(
        snapshots.map((QueueSnapshot s) => s.toMap()).toList(),
      );
      await _prefs.setString(PrefsKeys.queueHistory, json);
    } catch (e) {
      debugPrint('writeHistory failed: $e');
    }
  }

  // ------------------------------------------------------------ 播放统计

  /// 读取本机播放次数（neteaseId → count）
  Map<int, int> loadPlayStats() {
    final String? json = _prefs.getString(PrefsKeys.playStats);
    if (json == null || json.isEmpty) return const <int, int>{};
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) return const <int, int>{};
      return decoded.map((String k, Object? v) => MapEntry<int, int>(
          int.tryParse(k) ?? 0, (v as num?)?.toInt() ?? 0));
    } catch (e) {
      debugPrint('loadPlayStats failed: $e');
      return const <int, int>{};
    }
  }

  /// 播放计次 +1（仅统计有网易云 id 的曲目）
  Future<void> incrementPlay(int neteaseId) async {
    try {
      final Map<int, int> stats = Map<int, int>.of(loadPlayStats());
      stats[neteaseId] = (stats[neteaseId] ?? 0) + 1;
      // jsonEncode 不支持 int 键：转字符串键
      final String json = jsonEncode(<String, int>{
        for (final MapEntry<int, int> e in stats.entries)
          '${e.key}': e.value,
      });
      await _prefs.setString(PrefsKeys.playStats, json);
    } catch (e) {
      debugPrint('incrementPlay failed: $e');
    }
  }
}
