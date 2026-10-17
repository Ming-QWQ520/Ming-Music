/// 曲目仓库：内置演示曲目 + 用户添加的网络直链曲目（持久化）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/prefs_keys.dart';
import '../domain/track.dart';

class TrackRepository {
  TrackRepository(this._prefs);

  final SharedPreferences _prefs;

  /// 内置曲目 + 自定义网络曲目
  List<Track> loadTracks() {
    final List<Track> tracks = List<Track>.of(kBuiltinTracks);
    final String? raw = _prefs.getString(PrefsKeys.customTracks);
    if (raw != null) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List<Object?>) {
          tracks.addAll(decoded
              .whereType<Map<Object?, Object?>>()
              .map(Track.fromMap)
              .toList());
        }
      } catch (_) {
        // 脏数据忽略，不影响内置曲目
      }
    }
    return tracks;
  }

  Future<void> saveCustomTracks(List<Track> custom) async {
    await _prefs.setString(
      PrefsKeys.customTracks,
      jsonEncode(custom.map((Track t) => t.toMap()).toList()),
    );
  }

  /// 收藏列表（track id 集合）
  Set<String> loadFavorites() {
    return _prefs.getStringList(PrefsKeys.favorites)?.toSet() ?? <String>{};
  }

  Future<void> saveFavorites(Set<String> ids) async {
    await _prefs.setStringList(PrefsKeys.favorites, ids.toList());
  }
}
