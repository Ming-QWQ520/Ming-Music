import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';

import 'package:ming_music/features/player/domain/np_settings.dart';

void main() {
  group('NpPlayerSettings 序列化', () {
    test('默认值往返：toMap → fromMap 字段保全', () {
      final NpPlayerSettings s = NpPlayerSettings.defaults;
      final NpPlayerSettings restored = NpPlayerSettings.fromMap(s.toMap());

      expect(restored.displayMode, s.displayMode);
      expect(restored.coverStyle, s.coverStyle);
      expect(restored.coverScale, s.coverScale);
      expect(restored.coverShadow, s.coverShadow);
      expect(restored.bgBlur, s.bgBlur);
      expect(restored.bgDim, s.bgDim);
      expect(restored.lyricFontSize, s.lyricFontSize);
      expect(restored.lyricLineGap, s.lyricLineGap);
      expect(restored.lyricAlign, s.lyricAlign);
      expect(restored.showTranslation, s.showTranslation);
      expect(restored.lyricFade, s.lyricFade);
      expect(restored.lyricBlur, s.lyricBlur);
      expect(restored.yrcPlayed, s.yrcPlayed);
      expect(restored.yrcUnplayed, s.yrcUnplayed);
      expect(restored.highlightPlayed, s.highlightPlayed);
      expect(restored.heartEffect, s.heartEffect);
      expect(restored.miniStyle, s.miniStyle);
      expect(restored.stripButtons, s.stripButtons);
    });

    test('自定义值往返：全部非默认字段保全', () {
      const NpPlayerSettings s = NpPlayerSettings(
        displayMode: NpDisplayMode.lyrics,
        coverStyle: NpCoverStyle.circle,
        coverScale: 1.15,
        coverShadow: false,
        bgBlur: 8,
        bgDim: 30,
        lyricFontSize: 24,
        lyricLineGap: 30,
        lyricAlign: NpLyricAlign.center,
        showTranslation: false,
        lyricFade: 0.2,
        lyricBlur: 3,
        yrcPlayed: Color(0xFFFA233B),
        yrcUnplayed: Color(0x33FFFFFF),
        highlightPlayed: true,
        heartEffect: false,
        miniStyle: MiniPlayerStyle.wide,
        stripButtons: <String>['wiki', 'output'],
      );
      final NpPlayerSettings restored = NpPlayerSettings.fromMap(s.toMap());

      expect(restored, isNot(same(s)));
      expect(restored.displayMode, NpDisplayMode.lyrics);
      expect(restored.coverStyle, NpCoverStyle.circle);
      expect(restored.coverScale, closeTo(1.15, 1e-9));
      expect(restored.coverShadow, isFalse);
      expect(restored.bgBlur, 8);
      expect(restored.bgDim, 30);
      expect(restored.lyricFontSize, 24);
      expect(restored.lyricLineGap, 30);
      expect(restored.lyricAlign, NpLyricAlign.center);
      expect(restored.showTranslation, isFalse);
      expect(restored.lyricFade, closeTo(0.2, 1e-9));
      expect(restored.lyricBlur, 3);
      expect(restored.yrcPlayed, const Color(0xFFFA233B));
      expect(restored.yrcUnplayed, const Color(0x33FFFFFF));
      expect(restored.highlightPlayed, isTrue);
      expect(restored.heartEffect, isFalse);
      expect(restored.miniStyle, MiniPlayerStyle.wide);
      expect(restored.stripButtons, <String>['wiki', 'output']);
    });

    test('脏数据回退默认值：空 map / 非法枚举 / 越界数值', () {
      final NpPlayerSettings fromEmpty =
          NpPlayerSettings.fromMap(<Object?, Object?>{});
      expect(fromEmpty.displayMode, NpDisplayMode.both);
      expect(fromEmpty.coverStyle, NpCoverStyle.vinyl);
      expect(fromEmpty.lyricAlign, NpLyricAlign.left);
      expect(fromEmpty.miniStyle, MiniPlayerStyle.classic);
      expect(fromEmpty.stripButtons, kStripButtonDefaults);

      final NpPlayerSettings fromGarbage =
          NpPlayerSettings.fromMap(<Object?, Object?>{
        'displayMode': 'not-a-mode',
        'coverStyle': '???',
        'coverScale': 99, // 越界 → clamp 到 1.2
        'lyricFontSize': -5, // 越界 → clamp 到 12
        'yrcPlayed': 0xFF112233,
        'miniStyle': 'nope',
        'stripButtons': <String>['wiki', 'bogus-id', 'settings'],
      });
      expect(fromGarbage.displayMode, NpDisplayMode.both);
      expect(fromGarbage.coverStyle, NpCoverStyle.vinyl);
      expect(fromGarbage.coverScale, closeTo(1.2, 1e-9));
      expect(fromGarbage.lyricFontSize, 12);
      expect(fromGarbage.yrcPlayed, const Color(0xFF112233));
      expect(fromGarbage.miniStyle, MiniPlayerStyle.classic);
      // 非法按钮 id 被过滤，合法项按默认顺序保留
      expect(fromGarbage.stripButtons, <String>['wiki', 'settings']);
    });

    test('copyWith 局部更新不影响其他字段', () {
      const NpPlayerSettings base = NpPlayerSettings();
      final NpPlayerSettings updated = base.copyWith(
        bgBlur: 20,
        highlightPlayed: true,
      );
      expect(updated.bgBlur, 20);
      expect(updated.highlightPlayed, isTrue);
      expect(updated.displayMode, base.displayMode);
      expect(updated.lyricFontSize, base.lyricFontSize);
    });

    test('旧版本数据（含已废弃字段）向前兼容', () {
      // 旧数据含已移除的 directShowLyrics / hidePlayerControls /
      // animationSpeed：解析应忽略未知字段不报错
      final NpPlayerSettings legacy = NpPlayerSettings.fromMap(
          <Object?, Object?>{
        '_v': 1,
        'displayMode': 'both',
        'directShowLyrics': false, // 已废弃字段
        'hidePlayerControls': true, // 已移除（需求）
        'animationSpeed': 1.6, // 已移除（需求）
      });
      expect(legacy.displayMode, NpDisplayMode.both);
      expect(legacy.highlightPlayed, isFalse);
      expect(legacy.heartEffect, isTrue);
    });

    test('stripButtons 顺序按 kStripButtonIds 规范化', () {
      // setStripButtons 的排序逻辑在 notifier 层；fromMap 侧校验
      // 未知 id 过滤与默认回填
      final NpPlayerSettings s = NpPlayerSettings.fromMap(
          <Object?, Object?>{
        'stripButtons': <String>['settings', 'wiki'],
      });
      // fromMap 不过滤顺序（保存时已规范化），仅过滤非法 id
      expect(s.stripButtons, <String>['settings', 'wiki']);
    });
  });
}
