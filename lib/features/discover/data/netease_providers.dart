/// 网易云 API / 仓库 的全局 Provider 注入点 + 首页数据源。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_api.dart';
import '../../../core/api/netease_models.dart';
import '../../../core/storage/prefs_keys.dart';
import '../../settings/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import 'netease_repository.dart';

/// 全局唯一 NeteaseApi（main.dart 已注入 SharedPreferences）
final Provider<NeteaseApi> neteaseApiProvider = Provider<NeteaseApi>(
  (Ref ref) => NeteaseApi(ref.watch(sharedPreferencesProvider)),
);

/// 全局唯一 NeteaseRepository
final Provider<NeteaseRepository> neteaseRepositoryProvider =
    Provider<NeteaseRepository>(
  (Ref ref) => NeteaseRepository(ref.watch(neteaseApiProvider)),
);

/// 推荐歌单（游客可用）
final FutureProvider<List<PlaylistMeta>> personalizedProvider =
    FutureProvider<List<PlaylistMeta>>(
  (Ref ref) => ref.read(neteaseRepositoryProvider).personalized(limit: 12),
);

/// 热搜词（发现页 / 搜索页共用）
final FutureProvider<List<HotWord>> hotWordsProvider =
    FutureProvider<List<HotWord>>(
  (Ref ref) => ref.read(neteaseRepositoryProvider).hotSearch(),
);

/// 推荐新音乐（需求：发现页「推荐新音乐」板块，游客可用）
final FutureProvider<List<Song>> personalizedNewSongsProvider =
    FutureProvider<List<Song>>(
  (Ref ref) => ref.read(neteaseRepositoryProvider).personalizedNewSongs(),
);

/// 新歌速递（需求：发现页「新歌速递」板块，type=0 全部）
final FutureProvider<List<Song>> topNewSongsProvider =
    FutureProvider<List<Song>>(
  (Ref ref) => ref.read(neteaseRepositoryProvider).topSongs(type: 0, limit: 20),
);

/// 榜单精选预览（需求：榜单卡片下直接展示前 10 行可点）
final FutureProviderFamily<List<Song>, int> toplistPreviewProvider =
    FutureProvider.family<List<Song>, int>(
  (Ref ref, int id) =>
      ref.read(neteaseRepositoryProvider).toplistPreview(id, limit: 10),
);

/// 每日推荐歌单（登录后含「雷达歌单」分组，需求：雷达歌单入口）
final FutureProvider<List<PlaylistMeta>> dailyPlaylistProvider =
    FutureProvider<List<PlaylistMeta>>(
  (Ref ref) => ref.read(neteaseRepositoryProvider).recommendPlaylists(),
);

/// 每日推荐歌曲封面（第十二批需求：每日推荐卡片 2x2 拼贴铺底，
/// 对齐 Zephyr-Music 参考图的拼贴封面样式；未登录/失败由卡片回退
/// 品牌红渐变 + 日期数字）
final FutureProvider<List<String>> dailySongsCoversProvider =
    FutureProvider<List<String>>((Ref ref) async {
  final List<Song> songs =
      await ref.read(neteaseRepositoryProvider).recommendSongs();
  return <String>[
    for (final Song s in songs)
      if (s.coverUrl != null && s.coverUrl!.isNotEmpty) s.coverUrl!,
  ].take(4).toList(growable: false);
});

/// 私人雷达歌单封面（需求：发现页顶部个性化推荐类入口显示歌单封面，
/// 对齐 Zephyr-Music 推荐页 —— 轻量 /playlist/detail 只取 meta）。
/// 3136952023 = 网易云「私人雷达」固定歌单 id。
final FutureProvider<PlaylistMeta?> personalRadarMetaProvider =
    FutureProvider<PlaylistMeta?>((Ref ref) async {
  try {
    return await ref
        .read(neteaseRepositoryProvider)
        .playlistMetaLite(3136952023);
  } catch (_) {
    return null; // 未登录/接口异常：入口回退渐变图标
  }
});

/// 音乐云盘快照（第十五批需求：登录后自动同步云盘歌曲）：
///
///  - 登录成功后由 app.dart 监听 authProvider 预热读取（keepAlive，
///    非 autoDispose），云盘页/我的页云盘 tile 直接消费缓存数据，
///    打开即显示歌曲列表与总数，无需每次进页再拉取；
///  - 上传/删除后调用方 invalidate 本 provider 触发重新同步。
typedef CloudDriveSnapshot = (List<CloudSong>, CloudDriveInfo);

final FutureProvider<CloudDriveSnapshot> cloudDriveProvider =
    FutureProvider<CloudDriveSnapshot>((Ref ref) async {
  final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
  final List<dynamic> r = await Future.wait<dynamic>(<Future<dynamic>>[
    repo.cloudList(),
    repo.cloudInfo(),
  ]);
  return (r[0] as List<CloudSong>, r[1] as CloudDriveInfo);
});

// ---------------------------------------------------------------- 榜单精选自定义

/// 发现页「榜单精选」自定义勾选（需求：跟 Zephyr-Music 一样的自定义 ——
/// 持久化有序 id 列表；空/脏数据回退默认前 6 个榜单）
final NotifierProvider<DiscoverToplistNotifier, List<int>>
    discoverToplistIdsProvider =
    NotifierProvider<DiscoverToplistNotifier, List<int>>(
        DiscoverToplistNotifier.new);

class DiscoverToplistNotifier extends Notifier<List<int>> {
  @override
  List<int> build() {
    final String? raw = ref
        .watch(sharedPreferencesProvider)
        .getString(PrefsKeys.discoverToplists);
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List<Object?>) {
          final List<int> ids = decoded
              .whereType<num>()
              .map((num v) => v.toInt())
              .where((int id) => kToplists.any((ToplistConf t) => t.id == id))
              .toList();
          if (ids.isNotEmpty) return ids;
        }
      } catch (_) {
        // 脏数据 → 默认
      }
    }
    return <int>[
      for (final ToplistConf t in kToplists.take(6)) t.id,
    ];
  }

  void setIds(List<int> ids) {
    final List<int> valid = <int>[
      for (final int id in ids)
        if (kToplists.any((ToplistConf t) => t.id == id)) id,
    ];
    final List<int> ordered = <int>[];
    for (final int id in valid) {
      if (!ordered.contains(id)) ordered.add(id);
    }
    state = ordered.isEmpty
        ? <int>[for (final ToplistConf t in kToplists.take(6)) t.id]
        : ordered;
    ref
        .read(sharedPreferencesProvider)
        .setString(PrefsKeys.discoverToplists, jsonEncode(state));
  }
}
