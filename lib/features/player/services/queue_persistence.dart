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

  /// 保存当前队列状态（需求：歌单数据只保存歌曲 ID —— 网易云曲目仅存 id，
  /// 不再持久化播放直链（有效期短，重启后由 restore 阶段统一重新获取）。
  /// 本地/自定义曲目无法通过 id 重建，仍保存完整 Track。
  ///
  /// 格式 v2：{v:2, items:[<int id 或 track map>...], index, queueTitle}
  /// 兼容旧格式：{queue:[track map...], index, queueTitle}
  Future<void> saveQueueState(
    List<Track> queue,
    int index,
    String? queueTitle,
  ) async {
    try {
      final String json = jsonEncode(<String, Object?>{
        'v': 2,
        'items': <Object?>[
          for (final Track t in queue)
            t.neteaseId != null && t.neteaseId! > 0 ? t.neteaseId : t.toMap(),
        ],
        'index': index,
        'queueTitle': queueTitle,
      });
      await _prefs.setString(PrefsKeys.queueState, json);
    } catch (e) {
      debugPrint('saveQueueState failed: $e');
    }
  }

  /// 恢复队列状态的原始数据：网易云曲目仅返回 id（占位 Track，需上层
  /// 经 /song/detail 补全元数据后重新解析直链）；本地/自定义曲目直接还原。
  /// 无存档返回 null。
  ({List<Track> queue, int index, String? queueTitle, bool hasNeteaseIds})?
      loadQueueState() {
    final String? json = _prefs.getString(PrefsKeys.queueState);
    if (json == null || json.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) return null;

      final bool isV2 = decoded['v'] == 2;
      final Object? raw = isV2 ? decoded['items'] : decoded['queue'];
      if (raw is! List<Object?>) return null;

      final List<Track> tracks = <Track>[];
      bool hasNeteaseIds = false;
      for (final Object? item in raw) {
        if (isV2 && item is num) {
          // v2：网易云歌曲 id 占位（元数据由 restore 阶段批量补全）
          final int id = item.toInt();
          if (id <= 0) continue;
          hasNeteaseIds = true;
          tracks.add(Track(
            id: 'netease_$id',
            neteaseId: id,
            title: '加载中…',
            artist: '网易云',
            album: '',
            source: '',
            isNetwork: true,
          ));
        } else if (item is Map) {
          final Track t = Track.fromMap(item.cast<String, Object?>());
          // 旧格式（v1）：网易云曲目持久化了完整 Track（含已过期直链）——
          // 清空 source 强制重新解析（需求：退出重进自动刷新播放 URL）
          if (t.neteaseId != null && (t.neteaseId ?? 0) > 0) {
            hasNeteaseIds = true;
            if (!t.needsUrlResolve) {
              tracks.add(Track(
                id: t.id,
                neteaseId: t.neteaseId,
                mvId: t.mvId,
                title: t.title,
                artist: t.artist,
                album: t.album,
                source: '',
                cover: t.cover,
                durationMs: t.durationMs,
                isNetwork: t.isNetwork,
                isCustom: t.isCustom,
                fee: t.fee,
              ));
              continue;
            }
          }
          tracks.add(t);
        }
      }
      if (tracks.isEmpty) return null;
      final int index = ((decoded['index'] as num?)?.toInt() ?? 0)
          .clamp(0, tracks.length - 1);
      return (
        queue: tracks,
        index: index,
        queueTitle: decoded['queueTitle'] as String?,
        hasNeteaseIds: hasNeteaseIds,
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
    current.insert(
        0,
        QueueSnapshot(
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
      return decoded.map((String k, Object? v) =>
          MapEntry<int, int>(int.tryParse(k) ?? 0, (v as num?)?.toInt() ?? 0));
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
        for (final MapEntry<int, int> e in stats.entries) '${e.key}': e.value,
      });
      await _prefs.setString(PrefsKeys.playStats, json);
    } catch (e) {
      debugPrint('incrementPlay failed: $e');
    }
  }
}
