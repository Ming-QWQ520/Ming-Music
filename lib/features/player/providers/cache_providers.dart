/// 缓存体系状态层（需求：点击数据缓存可查看缓存的音乐 + 歌单页歌名
/// 按缓存状态着色）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart' show Song;
import '../../../core/utils/platform_actions.dart';
import '../../discover/data/netease_providers.dart'
    show neteaseRepositoryProvider;
import '../../library/domain/track.dart' show Track;
import '../services/queue_persistence.dart'
    show QueuePersistence, QueueSnapshot;
import '../services/song_cache.dart';
import 'player_providers.dart'
    show playerProvider, queuePersistenceProvider, songCacheProvider;

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
/// 元信息未记录」），本层检测到元信息缺失时批量回填（歌名/歌手/封面
/// 归一 200x200 后写入 meta.json），下次直读不再请求；
/// 需求（第二十四批）：回填改两段式多源 —— 服务端 /song/detail 为
/// 主源，失败/未命中的 id 再走官方旧版公开详情（music.163.com 匿名
/// 明文 GET）兜底，离线双源皆败保持原状不阻断列表；
/// 落盘写入经 saveEntryMeta 字段合并保护（非空优先）+ 原子 rename，
/// 并发回填不再互相抹除或写坏 meta.json。
final FutureProvider<List<CacheEntry>> cacheEntriesProvider =
    FutureProvider<List<CacheEntry>>((Ref ref) async {
  final SongCacheService cache = ref.watch(songCacheProvider);
  List<CacheEntry> entries = await cache.listEntries();

  // 单段回填：sources 任一命中即写入；返回仍缺信息的 id 集合
  Future<Set<int>> backfill(
      Set<int> ids, Future<List<Song>> Function(List<int>) fetch) async {
    final List<Song> songs = await fetch(ids.toList());
    final Set<int> unresolved = <int>{...ids};
    for (final Song s in songs) {
      final String cover = SongCacheService.normalizeCover200(s.coverUrl);
      // 同一歌曲可能存在多档音质缓存条目，元信息一并补齐
      for (final CacheEntry e in entries) {
        if (e.songId != s.id) continue;
        final bool needTitle = e.title.isEmpty && s.name.isNotEmpty;
        final bool needArtist = e.artist.isEmpty && s.artists.isNotEmpty;
        final bool needCover = e.cover.isEmpty && cover.isNotEmpty;
        if (!needTitle && !needArtist && !needCover) continue;
        await cache.saveEntryMeta(
          e.songId,
          e.level,
          title: needTitle ? s.name : '',
          artist: needArtist ? s.artists : '',
          cover: needCover ? cover : '',
        );
      }
      // 至少拿到一个非空字段即视为已解决（下次列表不再重复拉取）
      if (s.name.isNotEmpty || s.artists.isNotEmpty || cover.isNotEmpty) {
        unresolved.remove(s.id);
      }
    }
    return unresolved;
  }

  // ---------- 本地元数据挖掘（离线可用，需求第二十九批根治） ----------
  // 此前回填完全依赖网络，而查缓存页恰是离线场景（缓存页的核心价值），
  // 旧条目在线补全永远轮空。现先从本地持久化挖元数据：队列存档(v3)
  // 与队列历史快照都带真实标题/歌手/封面，且「边听边缓存」的歌必然
  // 经过播放队列，离线命中率极高；剩余缺失仍走下方网络两源。
  Set<int> missing = <int>{
    for (final CacheEntry e in entries)
      if (e.title.isEmpty || e.artist.isEmpty || e.cover.isEmpty) e.songId,
  };
  if (missing.isNotEmpty) {
    try {
      final QueuePersistence qp = ref.read(queuePersistenceProvider);
      final Map<int, Track> local = <int, Track>{};
      void mine(Iterable<Track> tracks) {
        for (final Track t in tracks) {
          final int? id = t.neteaseId;
          if (id == null || id <= 0) continue;
          if (t.title.isEmpty || t.title == '加载中…') continue; // 占位行
          if (t.artist.isEmpty && (t.cover ?? '').isEmpty) continue;
          local.putIfAbsent(id, () => t);
        }
      }

      final ({
        List<Track> queue,
        int index,
        String? queueTitle,
        bool hasNeteaseIds
      })? saved = qp.loadQueueState();
      if (saved != null) mine(saved.queue);
      for (final QueueSnapshot s in qp.loadHistory()) {
        mine(s.tracks);
      }
      // 当前内存队列兜底（刚播放过的歌必然在内）
      mine(ref.read(playerProvider).queue);
      if (local.isNotEmpty) {
        for (final CacheEntry e in entries) {
          if (!missing.contains(e.songId)) continue;
          final Track? t = local[e.songId];
          if (t == null) continue;
          final String cover = SongCacheService.normalizeCover200(t.cover);
          final bool needTitle = e.title.isEmpty && t.title.isNotEmpty;
          final bool needArtist = e.artist.isEmpty && t.artist.isNotEmpty;
          final bool needCover = e.cover.isEmpty && cover.isNotEmpty;
          if (!needTitle && !needArtist && !needCover) continue;
          await cache.saveEntryMeta(
            e.songId,
            e.level,
            title: needTitle ? t.title : '',
            artist: needArtist ? t.artist : '',
            cover: needCover ? cover : '',
          );
        }
        entries = await cache.listEntries();
        missing = <int>{
          for (final CacheEntry e in entries)
            if (e.title.isEmpty || e.artist.isEmpty || e.cover.isEmpty)
              e.songId,
        };
      }
    } catch (_) {
      // 本地挖掘失败不阻断：继续走网络回填
    }
  }

  if (missing.isNotEmpty) {
    Set<int> rest = missing;
    try {
      rest = await backfill(
          missing,
          (List<int> ids) =>
              ref.read(neteaseRepositoryProvider).songDetails(ids));
    } catch (_) {
      // 主源整体失败：全部交给备用源
    }
    if (rest.isNotEmpty) {
      try {
        await backfill(rest, (List<int> ids) async {
          final List<Song> out = <Song>[];
          // 官方旧版接口无批量上限但保守分批（≤50/批）
          for (int i = 0; i < ids.length; i += 50) {
            final List<int> chunk =
                ids.sublist(i, (i + 50).clamp(0, ids.length));
            out.addAll(await ref
                .read(neteaseRepositoryProvider)
                .songDetailsViaOfficial(chunk));
          }
          return out;
        });
      } catch (_) {
        // 备用源也失败（离线/风控）：按原条目展示
      }
    }
    entries = await cache.listEntries();
  }
  return entries;
});

/// 缓存变更后统一刷新（下载完成 / 删除 / 清空调用）
void refreshCacheProviders(Ref ref) {
  ref.invalidate(cachedSongIdsProvider);
  ref.invalidate(cacheEntriesProvider);
}
