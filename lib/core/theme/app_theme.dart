/// Material Design 3 主题构建。
///
/// 设计语言：深邃沉浸底色 + 紫罗兰主色 + 大圆角 + 轻微表面渐变，
/// 呼应 Zephyr-Music 的高级感方向。
library;

import 'package:flutter/material.dart';

import '../constants/app_constants.dart';

class AppTheme {
  AppTheme._();

  static const Color seedColor = AppConstants.brandColor;

  /// 未启用图片背景时的页面底色（亮/暗）
  static const Color lightScaffold = Color(0xFFF6F5FB);
  static const Color darkScaffoldFallback = Color(0xFF121212);

  /// [transparentScaffold]：需求「全局图片背景（除播放页外）」启用时，
  /// 页面底色透明化以透出 builder 层的背景图；未启用时保持实色底。
  static ThemeData light({bool transparentScaffold = false}) =>
      _base(Brightness.light, transparentScaffold: transparentScaffold);

  static ThemeData dark({bool transparentScaffold = false}) =>
      _base(Brightness.dark, transparentScaffold: transparentScaffold);

  static ThemeData _base(
    Brightness brightness, {
    bool transparentScaffold = false,
  }) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    final bool isDark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: transparentScaffold
          ? Colors.transparent
          : (isDark ? darkScaffoldFallback : lightScaffold),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
          letterSpacing: 0.2,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurface.withValues(alpha: 0.55)),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark
            ? Colors.white.withValues(alpha: 0.055)
            : Colors.white.withValues(alpha: 0.9),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.onSurface.withValues(alpha: 0.08),
        thickness: 1,
        space: 1,
      ),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
