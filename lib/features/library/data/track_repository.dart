/// 本地曲目仓库：收藏曲目（完整 Track 序列化）+ 用户自定义网络直链曲目。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/prefs_keys.dart';
import '../domain/track.dart';

class TrackRepository {
  TrackRepository(this._prefs);

  final SharedPreferences _prefs;

  /// 收藏曲目（含网易云在线曲目，播放时重新解析直链）
  List<Track> loadFavoriteTracks() {
    final String? raw = _prefs.getString(PrefsKeys.favorites);
    if (raw == null) return <Track>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List<Object?>) {
        return decoded
            .whereType<Map<Object?, Object?>>()
            .map(Track.fromMap)
            .toList();
      }
    } catch (_) {
      // 脏数据忽略
    }
    return <Track>[];
  }

  Future<void> saveFavoriteTracks(List<Track> tracks) async {
    await _prefs.setString(
      PrefsKeys.favorites,
      jsonEncode(tracks.map((Track t) => t.toMap()).toList()),
    );
  }

  /// 用户自定义网络直链曲目
  List<Track> loadCustomTracks() {
    final String? raw = _prefs.getString(PrefsKeys.customTracks);
    if (raw == null) return <Track>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List<Object?>) {
        return decoded
            .whereType<Map<Object?, Object?>>()
            .map(Track.fromMap)
            .toList();
      }
    } catch (_) {
      // 脏数据忽略
    }
    return <Track>[];
  }

  Future<void> saveCustomTracks(List<Track> custom) async {
    await _prefs.setString(
      PrefsKeys.customTracks,
      jsonEncode(custom.map((Track t) => t.toMap()).toList()),
    );
  }
}
