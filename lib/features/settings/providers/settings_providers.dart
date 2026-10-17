/// 设置域状态管理：
///  - BackgroundProvider：背景系统（模糊封面 / 纯色渐变 / 本地图片）
///  - LayoutProvider：播放页模块 DIY 排序（序列化到本地）
///  - GlassPref：液态玻璃偏好 + 低端机自动降级（避坑指南 2）
///  - ThemeMode：亮暗主题
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/app_constants.dart';

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

  void setGradientIndex(int index) {
    _commit(state.copyWith(
      type: BackgroundType.gradient,
      gradientIndex: index.clamp(0, kGradientPresets.length - 1),
    ));
  }

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

// ---------------------------------------------------------------- layout

final NotifierProvider<LayoutNotifier, LayoutConfig> layoutProvider =
    NotifierProvider<LayoutNotifier, LayoutConfig>(LayoutNotifier.new);

class LayoutNotifier extends Notifier<LayoutConfig> {
  late SharedPreferences _prefs;

  @override
  LayoutConfig build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final String? raw = _prefs.getString(PrefsKeys.layout);
    if (raw != null) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          final LayoutConfig cfg = LayoutConfig.fromMap(decoded);
          return LayoutConfig(cfg.normalized);
        }
      } catch (_) {}
    }
    return LayoutConfig.defaults;
  }

  /// 拖拽重排（ReorderableListView.onReorderItem 回调，newIndex 已自动修正），
  /// 序列化保存
  void reorder(int oldIndex, int newIndex) {
    final List<PlayerModule> list = List<PlayerModule>.of(state.modules);
    final PlayerModule item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    final LayoutConfig next = LayoutConfig(list);
    state = next;
    _prefs.setString(PrefsKeys.layout, jsonEncode(next.toMap()));
  }

  void reset() {
    state = LayoutConfig.defaults;
    _prefs.setString(PrefsKeys.layout, jsonEncode(state.toMap()));
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
