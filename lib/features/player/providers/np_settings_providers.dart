/// 播放页自定义设置 provider：加载 / 持久化 / 局部更新。
library;

import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/providers/settings_providers.dart';
import '../domain/np_settings.dart'
    show
        MiniPlayerStyle,
        NpCoverLyricsMode,
        NpCoverStyle,
        NpDisplayMode,
        NpLyricAlign,
        NpPlayerSettings,
        kStripButtonDefaults,
        kStripButtonIds;

final NotifierProvider<NpSettingsNotifier, NpPlayerSettings>
    npSettingsProvider = NotifierProvider<NpSettingsNotifier, NpPlayerSettings>(
        NpSettingsNotifier.new);

class NpSettingsNotifier extends Notifier<NpPlayerSettings> {
  @override
  NpPlayerSettings build() {
    final raw =
        ref.watch(sharedPreferencesProvider).getString(PrefsKeys.npSettings);
    if (raw == null || raw.isEmpty) return NpPlayerSettings.defaults;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return NpPlayerSettings.fromMap(decoded);
      }
    } catch (_) {
      // 脏数据 → 默认值
    }
    return NpPlayerSettings.defaults;
  }

  void _commit(NpPlayerSettings next) {
    state = next;
    ref
        .read(sharedPreferencesProvider)
        .setString(PrefsKeys.npSettings, jsonEncode(next.toMap()));
  }

  void update(NpPlayerSettings Function(NpPlayerSettings) fn) =>
      _commit(fn(state));

  void setDisplayMode(NpDisplayMode mode) =>
      _commit(state.copyWith(displayMode: mode));

  void setCoverStyle(NpCoverStyle style) =>
      _commit(state.copyWith(coverStyle: style));

  void setCoverScale(double scale) =>
      _commit(state.copyWith(coverScale: scale.clamp(0.70, 1.20)));

  void setCoverShadow(bool shadow) =>
      _commit(state.copyWith(coverShadow: shadow));

  void setMiniStyle(MiniPlayerStyle style) =>
      _commit(state.copyWith(miniStyle: style));

  // 第十二批需求：Mini 条颜色/透明度设置项已移除（底板统一无色玻璃），
  // 历史 setMiniColor / setMiniTransparency 一并删除；旧持久化 JSON
  // 中的 miniColor / miniTransparency 键由 fromMap 自然忽略。

  /// 播放页始终亮屏（需求：设置中可开启）
  void setPlayerKeepScreenOn(bool on) =>
      _commit(state.copyWith(playerKeepScreenOn: on));

  void setBgBlur(double px) => _commit(state.copyWith(bgBlur: px.clamp(0, 40)));

  void setBgDim(double pct) =>
      _commit(state.copyWith(bgDim: pct.clamp(0, 100)));

  void setLyricFontSize(double px) =>
      _commit(state.copyWith(lyricFontSize: px.clamp(12, 40)));

  void setLyricLineGap(double px) =>
      _commit(state.copyWith(lyricLineGap: px.clamp(8, 48)));

  void setLyricAlign(NpLyricAlign align) =>
      _commit(state.copyWith(lyricAlign: align));

  void setShowTranslation(bool show) =>
      _commit(state.copyWith(showTranslation: show));

  void setLyricFade(double v) =>
      _commit(state.copyWith(lyricFade: v.clamp(0, 1)));

  void setLyricBlur(double px) =>
      _commit(state.copyWith(lyricBlur: px.clamp(0, 10)));

  void setYrcColors(Color played, Color unplayed) =>
      _commit(state.copyWith(yrcPlayed: played, yrcUnplayed: unplayed));

  void setHighlightPlayed(bool on) =>
      _commit(state.copyWith(highlightPlayed: on));

  void setLyricAlwaysCenter(bool on) =>
      _commit(state.copyWith(lyricAlwaysCenter: on));

  void setCoverLyrics(NpCoverLyricsMode mode) =>
      _commit(state.copyWith(coverLyrics: mode));

  // 第十五批需求：红心动效已整体移除（模型字段/设置项/播放页动效），
  // 历史 setHeartEffect 删除；旧持久化 JSON 中的 heartEffect 键由
  // fromMap 自然忽略。

  void setShowMvBadge(bool on) => _commit(state.copyWith(showMvBadge: on));

  /// 底部功能条按钮显隐与顺序（需求：预览从左到右可拖动自定义）——
  /// 持久化保留用户拖动后的顺序（不再按 kStripButtonIds 重排），
  /// 仅过滤非法 id 与去重；全空时回退默认集合。
  void setStripButtons(List<String> enabled) {
    final List<String> ordered = <String>[];
    for (final String id in enabled) {
      if (kStripButtonIds.contains(id) && !ordered.contains(id)) {
        ordered.add(id);
      }
    }
    _commit(state.copyWith(
      stripButtons:
          ordered.isEmpty ? List<String>.of(kStripButtonDefaults) : ordered,
    ));
  }

  void reset() => _commit(NpPlayerSettings.defaults);
}
