/// 网易云 API / 仓库 的全局 Provider 注入点 + 首页数据源。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_api.dart';
import '../../../core/api/netease_models.dart';
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
