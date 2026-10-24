/// 设置域状态管理：
///  - BackgroundProvider：背景系统（模糊封面 / 纯色渐变 / 本地图片）
///  - GlassPref：液态玻璃偏好 + 低端机自动降级（避坑指南 2）
///  - ThemeMode：亮暗主题
///  - AudioQuality：网易云播放音质等级
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地存储键名由 core/storage/prefs_keys.dart 统一管理
/// （import 供本文件使用，export 供下游使用）
import '../../../core/storage/prefs_keys.dart';
export '../../../core/storage/prefs_keys.dart';

import '../domain/settings_models.dart';

/// 由 main.dart override 注入
final Provider<SharedPreferences> sharedPreferencesProvider =
    Provider<SharedPreferences>(
  (Ref ref) => throw UnimplementedError('必须在 main.dart 中 override 注入'),
);

// ---------------------------------------------------------------- background

final NotifierProvider<BackgroundNotifier, BackgroundConfig>
    backgroundProvider = NotifierProvider<BackgroundNotifier, BackgroundConfig>(
        BackgroundNotifier.new);

class BackgroundNotifier extends Notifier<BackgroundConfig> {
  late SharedPreferences _prefs;

  @override
  BackgroundConfig build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final String? raw = _prefs.getString(PrefsKeys.background);
    if (raw != null) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          return BackgroundConfig.fromMap(decoded);
        }
      } catch (_) {
        // 脏数据 → 使用默认配置
      }
    }
    return BackgroundConfig.defaults;
  }

  void _commit(BackgroundConfig next) {
    state = next;
    _prefs.setString(PrefsKeys.background, jsonEncode(next.toMap()));
  }

  void setType(BackgroundType type) => _commit(state.copyWith(type: type));

  /// 从相册选择本地图片并持久化（temp 文件会被系统回收，必须拷贝）
  Future<void> pickImage() async {
    final XFile? picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 88);
    if (picked == null) return;
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory bgDir = Directory('${docs.path}/backgrounds');
    if (!bgDir.existsSync()) bgDir.createSync(recursive: true);
    final String target =
        '${bgDir.path}/bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(picked.path).copy(target);
    // 清理旧背景文件，避免空间膨胀
    final String? old = state.imagePath;
    if (old != null && File(old).existsSync()) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
    _commit(state.copyWith(type: BackgroundType.image, imagePath: target));
  }

  void clearImage() {
    final String? old = state.imagePath;
    if (old != null && File(old).existsSync()) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
    _commit(state.copyWith(clearImage: true, type: BackgroundType.blurCover));
  }
}

// ---------------------------------------------------------------- liquid glass

/// 液态玻璃偏好
final NotifierProvider<GlassPrefNotifier, GlassPref> glassPrefProvider =
    NotifierProvider<GlassPrefNotifier, GlassPref>(GlassPrefNotifier.new);

class GlassPrefNotifier extends Notifier<GlassPref> {
  late SharedPreferences _prefs;

  @override
  GlassPref build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final String? raw = _prefs.getString(PrefsKeys.glassPref);
    if (raw != null) {
      return GlassPref.values.firstWhere(
        (GlassPref p) => p.name == raw,
        orElse: () => GlassPref.auto,
      );
    }
    return GlassPref.auto;
  }

  void set(GlassPref pref) {
    state = pref;
    _prefs.setString(PrefsKeys.glassPref, pref.name);
  }
}

// ---------------------------------------------------------------- 我的页歌单排列

/// 我的页歌单排列方式（需求：宫格/列表切换，默认宫格，持久化）
final NotifierProvider<LibraryLayoutNotifier, LibraryPlaylistLayout>
    libraryPlaylistLayoutProvider =
    NotifierProvider<LibraryLayoutNotifier, LibraryPlaylistLayout>(
        LibraryLayoutNotifier.new);

class LibraryLayoutNotifier extends Notifier<LibraryPlaylistLayout> {
  late SharedPreferences _prefs;

  @override
  LibraryPlaylistLayout build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final String? raw = _prefs.getString(PrefsKeys.libraryPlaylistLayout);
    if (raw != null) {
      return LibraryPlaylistLayout.values.firstWhere(
        (LibraryPlaylistLayout v) => v.name == raw,
        orElse: () => LibraryPlaylistLayout.grid,
      );
    }
    return LibraryPlaylistLayout.grid; // 需求：默认宫格排序
  }

  void set(LibraryPlaylistLayout layout) {
    state = layout;
    _prefs.setString(PrefsKeys.libraryPlaylistLayout, layout.name);
  }

  void toggle() => set(
        state == LibraryPlaylistLayout.grid
            ? LibraryPlaylistLayout.list
            : LibraryPlaylistLayout.grid,
      );
}

/// 设备是否具备流畅运行液态玻璃的能力（异步探测，默认按支持处理）
final FutureProvider<bool> deviceGlassCapableProvider =
    FutureProvider<bool>((Ref ref) async {
  try {
    if (!Platform.isAndroid) return true;
    final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt >= kGlassAutoMinSdk;
  } catch (_) {
    return true;
  }
});

/// 液态玻璃最终开关（UI 只读此值）
final Provider<bool> glassEnabledProvider = Provider<bool>((Ref ref) {
  final GlassPref pref = ref.watch(glassPrefProvider);
  switch (pref) {
    case GlassPref.on:
      return true;
    case GlassPref.off:
      return false;
    case GlassPref.auto:
      return ref.watch(deviceGlassCapableProvider).value ?? true;
  }
});

// ---------------------------------------------------------------- theme

final NotifierProvider<ThemeModeNotifier, ThemeMode> themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  late SharedPreferences _prefs;

  @override
  ThemeMode build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final String? raw = _prefs.getString(PrefsKeys.themeMode);
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.dark; // 沉浸式默认深色
    }
  }

  void set(ThemeMode mode) {
    state = mode;
    _prefs.setString(PrefsKeys.themeMode, mode.name);
  }
}

// ---------------------------------------------------------------- audio quality

final NotifierProvider<AudioQualityNotifier, AudioQuality>
    audioQualityProvider = NotifierProvider<AudioQualityNotifier, AudioQuality>(
        AudioQualityNotifier.new);

class AudioQualityNotifier extends Notifier<AudioQuality> {
  late SharedPreferences _prefs;

  @override
  AudioQuality build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return AudioQualityX.fromName(_prefs.getString(PrefsKeys.audioQuality));
  }

  void set(AudioQuality quality) {
    state = quality;
    _prefs.setString(PrefsKeys.audioQuality, quality.name);
  }
}

// ---------------------------------------------------------------- 边听边缓存 / 预加载

/// 边听边缓存（需求：默认开启，并非下载；缓存文件仅可在设置中清理）
final NotifierProvider<ListenCacheNotifier, bool> listenCacheProvider =
    NotifierProvider<ListenCacheNotifier, bool>(ListenCacheNotifier.new);

class ListenCacheNotifier extends Notifier<bool> {
  late SharedPreferences _prefs;

  @override
  bool build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return _prefs.getBool(PrefsKeys.listenCache) ?? true;
  }

  void set(bool on) {
    state = on;
    _prefs.setBool(PrefsKeys.listenCache, on);
  }
}

/// 预加载下一首（需求：默认开启；开启缓存时预下载，否则预热连接）
final NotifierProvider<PreloadNextNotifier, bool> preloadNextProvider =
    NotifierProvider<PreloadNextNotifier, bool>(PreloadNextNotifier.new);

class PreloadNextNotifier extends Notifier<bool> {
  late SharedPreferences _prefs;

  @override
  bool build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return _prefs.getBool(PrefsKeys.preloadNext) ?? true;
  }

  void set(bool on) {
    state = on;
    _prefs.setBool(PrefsKeys.preloadNext, on);
  }
}

// ---------------------------------------------------------------- LRU 缓存上限

/// LRU 缓存容量上限（字节）：需求「默认最大缓存 3GB，可在缓存音乐页
/// 自行更改最大缓存，也可关闭此功能（关闭走确认弹窗）」。
/// 纯持久化状态；与 SongCacheService 的同步由 player 层
/// cacheConfigSyncProvider 统一执行（避免循环依赖）。
final NotifierProvider<CacheLimitNotifier, int> cacheLimitProvider =
    NotifierProvider<CacheLimitNotifier, int>(CacheLimitNotifier.new);

class CacheLimitNotifier extends Notifier<int> {
  late SharedPreferences _prefs;

  @override
  int build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final int saved = _prefs.getInt(PrefsKeys.cacheMaxBytes) ?? 0;
    if (saved > 0) return saved;
    return 3 * 1024 * 1024 * 1024; // 默认 3GB（需求）
  }

  void set(int bytes) {
    // 下限 512MB，防止误设极小值导致频繁清理
    final int v = bytes < 512 * 1024 * 1024 ? 512 * 1024 * 1024 : bytes;
    state = v;
    _prefs.setInt(PrefsKeys.cacheMaxBytes, v);
  }
}

// ---------------------------------------------------------------- 应用图片背景

/// 应用图片背景配置（需求：除播放页面外的全局图片背景）：
/// enabled=false 时所有页面回退主题纯色底。
class AppBackgroundConfig {
  const AppBackgroundConfig({this.enabled = false, this.imagePath});

  static const AppBackgroundConfig defaults = AppBackgroundConfig();

  final bool enabled;
  final String? imagePath;

  Object get identityKey => '$enabled-${imagePath ?? 'none'}';

  Map<String, Object?> toMap() => <String, Object?>{
        'enabled': enabled,
        'imagePath': imagePath,
      };

  AppBackgroundConfig copyWith({bool? enabled, String? imagePath}) {
    return AppBackgroundConfig(
      enabled: enabled ?? this.enabled,
      imagePath: imagePath ?? this.imagePath,
    );
  }

  static AppBackgroundConfig fromMap(Map<Object?, Object?> map) {
    return AppBackgroundConfig(
      enabled: map['enabled'] == true,
      imagePath: map['imagePath'] as String?,
    );
  }
}

final NotifierProvider<AppBackgroundNotifier, AppBackgroundConfig>
    appBackgroundProvider =
    NotifierProvider<AppBackgroundNotifier, AppBackgroundConfig>(
        AppBackgroundNotifier.new);

class AppBackgroundNotifier extends Notifier<AppBackgroundConfig> {
  late SharedPreferences _prefs;

  @override
  AppBackgroundConfig build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final String? raw = _prefs.getString(PrefsKeys.appBackground);
    if (raw != null) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          return AppBackgroundConfig.fromMap(decoded);
        }
      } catch (_) {
        // 脏数据 → 默认
      }
    }
    return AppBackgroundConfig.defaults;
  }

  void _commit(AppBackgroundConfig next) {
    state = next;
    _prefs.setString(PrefsKeys.appBackground, jsonEncode(next.toMap()));
  }

  /// 从相册选择图片并持久化（temp 文件会被系统回收，必须拷贝）
  Future<void> pickImage() async {
    final XFile? picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory bgDir = Directory('${docs.path}/app_backgrounds');
    if (!bgDir.existsSync()) bgDir.createSync(recursive: true);
    final String target =
        '${bgDir.path}/app_bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(picked.path).copy(target);
    // 清理旧图避免空间膨胀
    final String? old = state.imagePath;
    if (old != null && File(old).existsSync()) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
    _commit(AppBackgroundConfig(enabled: true, imagePath: target));
  }

  void setEnabled(bool on) => _commit(state.copyWith(enabled: on));

  void clear() {
    final String? old = state.imagePath;
    if (old != null && File(old).existsSync()) {
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
    _commit(AppBackgroundConfig.defaults);
  }
}
