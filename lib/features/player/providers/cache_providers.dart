/// 缓存体系状态层（需求：点击数据缓存可查看缓存的音乐 + 歌单页歌名
/// 按缓存状态着色）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart' show Song;
import '../../../core/utils/platform_actions.dart';
import '../../discover/data/netease_providers.dart'
    show neteaseRepositoryProvider;
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

/// 缓存条目列表（缓存列表页；删除/清空/新增后 invalidate 刷新）。
///
/// 需求（第二十一批）：数据缓存中的歌曲缓存需要显示歌曲名称、歌手名称
/// 和封面（200x200）—— 旧版本缓存没有落盘展示元信息（只显示「歌曲 id /
/// 元信息未记录」），本层检测到元信息缺失时经 /song/detail 批量回填
/// （歌名/歌手/封面归一 200x200 后写入 meta.json），下次直读不再请求；
/// 离线回填失败保持原状不阻断列表。
final FutureProvider<List<CacheEntry>> cacheEntriesProvider =
    FutureProvider<List<CacheEntry>>((Ref ref) async {
  final SongCacheService cache = ref.watch(songCacheProvider);
  List<CacheEntry> entries = await cache.listEntries();

  final Set<int> missing = <int>{
    for (final CacheEntry e in entries)
      if (e.title.isEmpty || e.artist.isEmpty || e.cover.isEmpty) e.songId,
  };
  if (missing.isNotEmpty) {
    try {
      final List<Song> songs = await ref
          .read(neteaseRepositoryProvider)
          .songDetails(missing.toList());
      for (final Song s in songs) {
        final String cover = SongCacheService.normalizeCover200(s.coverUrl);
        // 同一歌曲可能存在多档音质缓存条目，元信息一并补齐
        for (final CacheEntry e in entries) {
          if (e.songId != s.id) continue;
          await cache.saveEntryMeta(
            e.songId,
            e.level,
            title: s.name,
            artist: s.artists,
            cover: cover,
          );
        }
      }
      entries = await cache.listEntries();
    } catch (_) {
      // 回填失败（离线/接口异常）：按原条目展示
    }
  }
  return entries;
});

/// 缓存变更后统一刷新（下载完成 / 删除 / 清空调用）
void refreshCacheProviders(Ref ref) {
  ref.invalidate(cachedSongIdsProvider);
  ref.invalidate(cacheEntriesProvider);
}
