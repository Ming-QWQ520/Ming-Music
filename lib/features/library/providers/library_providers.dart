/// 我的音乐状态：收藏曲目 + 自定义网络直链曲目。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import '../data/track_repository.dart';
import '../domain/track.dart';

/// 用户自定义网络直链曲目
final NotifierProvider<LibraryNotifier, List<Track>> libraryProvider =
    NotifierProvider<LibraryNotifier, List<Track>>(LibraryNotifier.new);

class LibraryNotifier extends Notifier<List<Track>> {
  late TrackRepository _repo;

  @override
  List<Track> build() {
    _repo = TrackRepository(ref.watch(sharedPreferencesProvider));
    return _repo.loadCustomTracks();
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
    final List<Track> custom = List<Track>.of(state)..add(track);
    await _repo.saveCustomTracks(custom);
    state = custom;
    return true;
  }

  /// 移除自定义曲目（id 不存在时静默忽略）
  Future<void> removeCustomTrack(String id) async {
    final bool exists = state.any((Track t) => t.id == id);
    if (!exists || state.isEmpty) return;
    final List<Track> custom = state.where((Track t) => t.id != id).toList();
    await _repo.saveCustomTracks(custom);
    state = custom;
    // 同步取消收藏
    ref.read(favoriteTracksProvider.notifier).removeById(id);
  }
}

/// 收藏曲目列表（完整 Track 序列化，网易云在线歌曲可离线保留元信息）
final NotifierProvider<FavoriteNotifier, List<Track>> favoriteTracksProvider =
    NotifierProvider<FavoriteNotifier, List<Track>>(FavoriteNotifier.new);

class FavoriteNotifier extends Notifier<List<Track>> {
  late TrackRepository _repo;

  @override
  List<Track> build() {
    _repo = TrackRepository(ref.watch(sharedPreferencesProvider));
    return _repo.loadFavoriteTracks();
  }

  bool contains(String id) => state.any((Track t) => t.id == id);

  /// 切换收藏（网易云歌曲入队时携带解析好的直链，恢复时按 neteaseId 重新解析）
  Future<void> toggle(Track track) async {
    final List<Track> next = List<Track>.of(state);
    final int index = next.indexWhere((Track t) => t.id == track.id);
    if (index >= 0) {
      next.removeAt(index);
    } else {
      // 收藏时丢弃易过期的直链，仅保留元信息（播放时重新解析）
      next.insert(0, track.copyWith(source: ''));
      if (next.length > 500) next.removeRange(500, next.length);
    }
    state = next;
    await _repo.saveFavoriteTracks(next);
  }

  Future<void> removeById(String id) async {
    final bool exists = state.any((Track t) => t.id == id);
    if (!exists) return;
    final List<Track> next = state.where((Track t) => t.id != id).toList();
    state = next;
    await _repo.saveFavoriteTracks(next);
  }
}
