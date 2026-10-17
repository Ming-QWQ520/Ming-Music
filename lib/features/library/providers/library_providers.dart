/// 音乐库状态：曲目列表 + 收藏。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import '../data/track_repository.dart';
import '../domain/track.dart';

/// 曲目列表（内置 + 自定义网络曲目）
final NotifierProvider<LibraryNotifier, List<Track>> libraryProvider =
    NotifierProvider<LibraryNotifier, List<Track>>(LibraryNotifier.new);

class LibraryNotifier extends Notifier<List<Track>> {
  late TrackRepository _repo;

  @override
  List<Track> build() {
    _repo = TrackRepository(ref.watch(sharedPreferencesProvider));
    return _repo.loadTracks();
  }

  /// 添加网络直链曲目
  Future<bool> addNetworkTrack({
    required String title,
    required String artist,
    required String url,
  }) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return false;
    }
    final Track track = Track(
      id: 'net_${DateTime.now().millisecondsSinceEpoch}',
      title: title.trim().isEmpty ? '网络曲目' : title.trim(),
      artist: artist.trim().isEmpty ? '未知歌手' : artist.trim(),
      album: '网络直链',
      source: url,
      isNetwork: true,
      isCustom: true,
    );
    final List<Track> custom = state.where((Track t) => t.isCustom).toList()
      ..add(track);
    await _repo.saveCustomTracks(custom);
    state = <Track>[...state, track];
    return true;
  }

  /// 移除自定义曲目（内置曲目不可移除；id 不存在时静默忽略）
  Future<void> removeCustomTrack(String id) async {
    // 先确认存在且为自定义曲目（避免空列表 first / orElse 误取）
    final bool exists = state.any((Track t) => t.id == id);
    if (!exists || state.isEmpty) return;
    final Track target = state.firstWhere((Track t) => t.id == id);
    if (!target.isCustom) return;
    final List<Track> custom =
        state.where((Track t) => t.isCustom && t.id != id).toList();
    await _repo.saveCustomTracks(custom);
    state = state.where((Track t) => t.id != id).toList();
    // 同步取消收藏
    ref.read(favoriteIdsProvider.notifier).remove(id);
  }
}

/// 收藏集合
final NotifierProvider<FavoriteNotifier, Set<String>> favoriteIdsProvider =
    NotifierProvider<FavoriteNotifier, Set<String>>(FavoriteNotifier.new);

class FavoriteNotifier extends Notifier<Set<String>> {
  late TrackRepository _repo;

  @override
  Set<String> build() {
    _repo = TrackRepository(ref.watch(sharedPreferencesProvider));
    return _repo.loadFavorites();
  }

  void toggle(String id) {
    final Set<String> next = Set<String>.of(state);
    if (!next.remove(id)) next.add(id);
    state = next;
    _repo.saveFavorites(next);
  }

  void remove(String id) {
    if (!state.contains(id)) return;
    final Set<String> next = Set<String>.of(state)..remove(id);
    state = next;
    _repo.saveFavorites(next);
  }

  bool contains(String id) => state.contains(id);
}
