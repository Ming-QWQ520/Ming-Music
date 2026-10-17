import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';

import 'package:ming_music/features/player/domain/np_settings.dart';

void main() {
  group('NpPlayerSettings 序列化', () {
    test('默认值往返：toMap → fromMap 字段保全', () {
      final NpPlayerSettings s = NpPlayerSettings.defaults;
      final NpPlayerSettings restored = NpPlayerSettings.fromMap(s.toMap());

      expect(restored.displayMode, s.displayMode);
      expect(restored.hidePlayerControls, s.hidePlayerControls);
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
      expect(restored.directShowLyrics, s.directShowLyrics);
      expect(restored.animationSpeed, s.animationSpeed);
    });

    test('自定义值往返：全部非默认字段保全', () {
      const NpPlayerSettings s = NpPlayerSettings(
        displayMode: NpDisplayMode.lyrics,
        hidePlayerControls: true,
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
        directShowLyrics: false,
        animationSpeed: 1.6,
      );
      final NpPlayerSettings restored = NpPlayerSettings.fromMap(s.toMap());

      expect(restored, isNot(same(s)));
      expect(restored.displayMode, NpDisplayMode.lyrics);
      expect(restored.hidePlayerControls, isTrue);
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
      expect(restored.directShowLyrics, isFalse);
      expect(restored.animationSpeed, closeTo(1.6, 1e-9));
    });

    test('脏数据回退默认值：空 map / 非法枚举 / 越界数值', () {
      final NpPlayerSettings fromEmpty =
          NpPlayerSettings.fromMap(<Object?, Object?>{});
      expect(fromEmpty.displayMode, NpDisplayMode.both);
      expect(fromEmpty.coverStyle, NpCoverStyle.vinyl);
      expect(fromEmpty.lyricAlign, NpLyricAlign.left);

      final NpPlayerSettings fromGarbage =
          NpPlayerSettings.fromMap(<Object?, Object?>{
        'displayMode': 'not-a-mode',
        'coverStyle': '???',
        'coverScale': 99, // 越界 → clamp 到 1.2
        'lyricFontSize': -5, // 越界 → clamp 到 12
        'yrcPlayed': 0xFF112233,
      });
      expect(fromGarbage.displayMode, NpDisplayMode.both);
      expect(fromGarbage.coverStyle, NpCoverStyle.vinyl);
      expect(fromGarbage.coverScale, closeTo(1.2, 1e-9));
      expect(fromGarbage.lyricFontSize, 12);
      expect(fromGarbage.yrcPlayed, const Color(0xFF112233));
    });

    test('copyWith 局部更新不影响其他字段', () {
      const NpPlayerSettings base = NpPlayerSettings();
      final NpPlayerSettings updated = base.copyWith(
        bgBlur: 20,
        directShowLyrics: false,
      );
      expect(updated.bgBlur, 20);
      expect(updated.directShowLyrics, isFalse);
      expect(updated.displayMode, base.displayMode);
      expect(updated.lyricFontSize, base.lyricFontSize);
    });
  });
}
