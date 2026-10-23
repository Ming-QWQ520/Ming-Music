/// 缓存体系状态层（需求：点击数据缓存可查看缓存的音乐 + 歌单页歌名
/// 按缓存状态着色）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/platform_actions.dart';
import '../services/song_cache.dart';
import 'player_providers.dart' show songCacheProvider;

/// 已缓存音频的歌曲 id 集合（列表页歌名着色：已缓存正常 / 未缓存暗淡）
final FutureProvider<Set<int>> cachedSongIdsProvider =
    FutureProvider<Set<int>>((Ref ref) {
  return ref.watch(songCacheProvider).cachedSongIds();
});

/// 网络可用性（原生探测，需求：暗淡仅发生在「无网且未缓存」）。
///
/// 有网时所有歌曲一律正常显示；仅无网时未缓存歌曲暗淡。
/// 实现方式：8 秒轮询原生探测（一次 binder 调用，成本可忽略）；
/// 探测失败按有网处理（宁可少暗淡不误暗淡）。
/// 监听侧请用 `select` 提取布尔值，值不变不触发重建。
final StreamProvider<bool> networkAvailableProvider =
    StreamProvider<bool>((Ref ref) async* {
  while (true) {
    yield await PlatformActions.isNetworkAvailable();
    await Future<void>.delayed(const Duration(seconds: 8));
  }
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
