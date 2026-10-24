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
    // 第十六批需求：历史播放「继续播放：X」—— 快照入历史时记录
    // 当前播放到哪一首（恢复时从此首继续）
    this.currentIndex = 0,
  });

  final String title;
  final List<Track> tracks;
  final DateTime savedAt;

  /// 快照时的播放位置（clamp 在曲目范围内）
  final int currentIndex;

  Map<String, Object?> toMap() => <String, Object?>{
        'title': title,
        'tracks': tracks.map((Track t) => t.toMap()).toList(),
        'savedAt': savedAt.millisecondsSinceEpoch,
        'currentIndex': currentIndex,
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
    final int idx = ((map['currentIndex'] as num?)?.toInt() ?? 0)
        .clamp(0, tracks.isEmpty ? 0 : tracks.length - 1);
    return QueueSnapshot(
      title: (map['title'] as String?) ?? '播放列表',
      tracks: tracks,
      savedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      currentIndex: idx,
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
  /// 第十七批修正（v3）：网易云曲目在 id 之外**额外落盘展示元数据**
  /// （标题/歌手/专辑/封面/时长/fee 等，不含直链）—— v2 只存 id 时，
  /// 重启恢复的队列全是「加载中…」占位行，元数据补全失败（离线/接口抖动）
  /// 就永远停在加载中（用户实测反馈：Mini 条不显示歌曲和封面而显示加载中）。
  /// v3 让重启后 UI 立即显示真实歌曲信息，直链仍在 restore 阶段重解析。
  ///
  /// 格式 v3：{v:3, items:[<track map（netease 曲目 source 置空）或 track map>...],
  /// index, queueTitle}
  /// 兼容 v2：{v:2, items:[<int id 或 track map>...]}（网易云条目为纯 id）
  /// 兼容旧格式：{queue:[track map...], index, queueTitle}
  Future<void> saveQueueState(
    List<Track> queue,
    int index,
    String? queueTitle,
  ) async {
    try {
      final String json = jsonEncode(<String, Object?>{
        'v': 3,
        'items': <Object?>[
          for (final Track t in queue)
            t.neteaseId != null && t.neteaseId! > 0
                // 网易云曲目：完整元数据 + 置空直链（直链 20 分钟过期，不落盘）
                ? t.copyWith(source: '').toMap()
                : t.toMap(),
        ],
        'index': index,
        'queueTitle': queueTitle,
      });
      await _prefs.setString(PrefsKeys.queueState, json);
    } catch (e) {
      debugPrint('saveQueueState failed: $e');
    }
  }

  /// 恢复队列状态的原始数据：
  ///  - v3：网易云曲目返回带元数据的 Track（source 已置空，需上层重新解析
  ///    直链），UI 可立即显示真实歌曲信息；
  ///  - v2：网易云曲目仅返回 id（「加载中…」占位，需上层经 /song/detail
  ///    补全元数据）；本地/自定义曲目直接还原；
  /// 无存档返回 null。
  ({List<Track> queue, int index, String? queueTitle, bool hasNeteaseIds})?
      loadQueueState() {
    final String? json = _prefs.getString(PrefsKeys.queueState);
    if (json == null || json.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) return null;

      final int v = (decoded['v'] as num?)?.toInt() ?? 0;
      final bool hasItemsKey = v == 2 || v == 3;
      final Object? raw =
          hasItemsKey ? decoded['items'] : decoded['queue'];
      if (raw is! List<Object?>) return null;

      final List<Track> tracks = <Track>[];
      bool hasNeteaseIds = false;
      for (final Object? item in raw) {
        if (v == 2 && item is num) {
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
          // 网易云曲目（v3 落盘 source 已置空 / v1 旧档持久化了已过期直链）：
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
                artistId: t.artistId,
                albumId: t.albumId,
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

  /// 推入历史快照（去重、最多保留 [maxHistory] 个，最新在前；
  /// [currentIndex] = 入历史时的播放位置，供「继续播放」显示与恢复）
  Future<List<QueueSnapshot>> pushHistory(
    String title,
    List<Track> tracks, {
    int maxHistory = 3,
    int currentIndex = 0,
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
          currentIndex: currentIndex.clamp(0, tracks.length - 1),
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
