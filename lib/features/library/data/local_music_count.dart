/// 本地音乐扫描计数（第十五批需求）：
///
/// 用户进入本地音乐页并授权同意后完成扫描，扫描结果数量持久化到
/// SharedPreferences；我的页「本地音乐」tile 副标题读取此值显示
/// 歌曲总数（未扫描过时回退提示文案）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/prefs_keys.dart';
import '../../settings/providers/settings_providers.dart'
    show sharedPreferencesProvider;

final NotifierProvider<LocalMusicCountNotifier, int?> localMusicCountProvider =
    NotifierProvider<LocalMusicCountNotifier, int?>(
        LocalMusicCountNotifier.new);

class LocalMusicCountNotifier extends Notifier<int?> {
  late SharedPreferences _prefs;

  @override
  int? build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return _prefs.getInt(PrefsKeys.localMusicCount);
  }

  /// 扫描完成（授权同意后）记录总数；权限拒绝/扫描失败不调用
  void set(int count) {
    state = count;
    _prefs.setInt(PrefsKeys.localMusicCount, count);
  }
}
