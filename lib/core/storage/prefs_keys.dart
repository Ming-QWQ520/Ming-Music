/// SharedPreferences 键名注册表（跨 feature 共享，集中管理防漂移）。
library;

class PrefsKeys {
  PrefsKeys._();

  static const String background = 'settings.background';
  static const String layout = 'settings.layout';
  static const String glassPref = 'settings.glassPref';
  static const String themeMode = 'settings.themeMode';
  static const String favorites = 'library.favorites';
  static const String customTracks = 'library.customTracks';
}
