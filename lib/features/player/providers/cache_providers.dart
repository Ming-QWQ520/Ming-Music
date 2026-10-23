/// 缓存体系状态层（需求：点击数据缓存可查看缓存的音乐 + 歌单页歌名
/// 按缓存状态着色）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/song_cache.dart';
import 'player_providers.dart' show songCacheProvider;

/// 已缓存音频的歌曲 id 集合（列表页歌名着色：已缓存正常 / 未缓存暗淡）
final FutureProvider<Set<int>> cachedSongIdsProvider =
    FutureProvider<Set<int>>((Ref ref) {
  return ref.watch(songCacheProvider).cachedSongIds();
});

/// 缓存条目列表（缓存列表页；删除/清空/新增后 invalidate 刷新）
final FutureProvider<List<CacheEntry>> cacheEntriesProvider =
    FutureProvider<List<CacheEntry>>((Ref ref) {
  return ref.watch(songCacheProvider).listEntries();
});

/// 缓存变更后统一刷新（下载完成 / 删除 / 清空调用）
void refreshCacheProviders(Ref ref) {
  ref.invalidate(cachedSongIdsProvider);
  ref.invalidate(cacheEntriesProvider);
}
