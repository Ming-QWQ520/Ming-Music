/// 播放页自定义设置（参考 Zephyr-Music PlayerSettings）：
///
///  - 显示模式（双列/仅封面/仅歌词）、隐藏控制栏；
///  - 封面样式（黑胶/圆角方形/圆形）+ 缩放 + 阴影；
///  - 背景模糊/变暗强度；
///  - 歌词排版（字号/行距/对齐/翻译/淡出/模糊）与逐字着色；
///  - 视图切换固定直显当前歌词（不再作为设置项）。
///
/// 持久化为单一 JSON key（PrefsKeys.npSettings），带版本号迁移
/// （仿 Zephyr rnp-settings + SETTINGS_VERSION）。
library;

import 'dart:ui' show Color;

/// 播放页显示模式
enum NpDisplayMode {
  /// 平板：双列（封面+歌词）；手机：封面⇄歌词可切换
  both,

  /// 锁定仅封面
  cover,

  /// 锁定仅歌词
  lyrics,
}

extension NpDisplayModeX on NpDisplayMode {
  String get label => switch (this) {
        NpDisplayMode.both => '自适应',
        NpDisplayMode.cover => '仅封面',
        NpDisplayMode.lyrics => '仅歌词',
      };
}

/// Mini 播放条样式（不止变配色 —— 各样式的组件布局完全不同）
enum MiniPlayerStyle {
  /// 经典条：封面左 + 「歌名 - 歌手」 + 圆环播放键 + 播放列表
  classic,

  /// 封面铺满：封面作背景 + 渐变遮罩 + 文字压在封面上 + 右侧圆钮
  overlay,

  /// 紧凑极简：仅封面（圆环进度绕封面）+ 小号播放键，无文字
  compact,

  /// 宽幅双行：大封面 + 歌名/歌手双行 + 底部细进度线
  wide,
}

extension MiniPlayerStyleX on MiniPlayerStyle {
  String get label => switch (this) {
        MiniPlayerStyle.classic => '经典条',
        MiniPlayerStyle.overlay => '封面铺满',
        MiniPlayerStyle.compact => '紧凑极简',
        MiniPlayerStyle.wide => '宽幅双行',
      };
}

/// 封面样式
enum NpCoverStyle { vinyl, square, circle }

extension NpCoverStyleX on NpCoverStyle {
  String get label => switch (this) {
        NpCoverStyle.vinyl => '黑胶唱片',
        NpCoverStyle.square => '圆角方形',
        NpCoverStyle.circle => '圆形',
      };
}

/// 歌词水平对齐
enum NpLyricAlign { left, center }

extension NpLyricAlignX on NpLyricAlign {
  String get label => switch (this) {
        NpLyricAlign.left => '左对齐',
        NpLyricAlign.center => '居中',
      };
}

class NpPlayerSettings {
  const NpPlayerSettings({
    this.displayMode = NpDisplayMode.both,
    this.hidePlayerControls = false,
    this.coverStyle = NpCoverStyle.vinyl,
    this.coverScale = 1.0,
    this.coverShadow = true,
    this.squareCoverRadius = false,
    this.bgBlur = 22,
    this.bgDim = 55,
    this.lyricFontSize = 17,
    this.lyricLineGap = 14,
    this.lyricAlign = NpLyricAlign.left,
    this.showTranslation = true,
    this.lyricFade = 0.55,
    this.lyricBlur = 0,
    this.yrcPlayed = const Color(0xFFFFFFFF),
    this.yrcUnplayed = const Color(0x66FFFFFF),
    this.animationSpeed = 1.0,
    this.miniStyle = MiniPlayerStyle.classic,
  });

  static const int version = 1;

  static const NpPlayerSettings defaults = NpPlayerSettings();

  // ---- 显示 ----

  /// 显示模式（平板双列 / 锁定单视图）
  final NpDisplayMode displayMode;

  /// 隐藏控制栏（仅保留进度条与手势，Zephyr hidePlayerControls）
  final bool hidePlayerControls;

  // ---- 封面 ----

  /// 封面样式
  final NpCoverStyle coverStyle;

  /// 封面缩放（0.70 - 1.20）
  final double coverScale;

  /// 封面投影
  final bool coverShadow;

  /// 方形封面圆角开关（需求：默认无圆角，可自定义开启）
  final bool squareCoverRadius;

  /// Mini 播放条样式
  final MiniPlayerStyle miniStyle;

  // ---- 背景 ----

  /// 背景模糊强度 px（0 - 40）
  final double bgBlur;

  /// 背景变暗 %（0 - 100）
  final double bgDim;

  // ---- 歌词 ----

  /// 歌词字号 px（12 - 40）
  final double lyricFontSize;

  /// 行距 px（8 - 48）
  final double lyricLineGap;

  /// 当前行对齐
  final NpLyricAlign lyricAlign;

  /// 显示翻译副行
  final bool showTranslation;

  /// 非活跃行淡出强度（0 - 1）
  final double lyricFade;

  /// 非活跃行模糊 px（0 - 10）
  final double lyricBlur;

  /// 逐字已唱颜色
  final Color yrcPlayed;

  /// 逐字未唱颜色
  final Color yrcUnplayed;

  /// 自动跟随滚动动画时长倍率（0.5 - 2.0）
  final double animationSpeed;

  NpPlayerSettings copyWith({
    NpDisplayMode? displayMode,
    bool? hidePlayerControls,
    NpCoverStyle? coverStyle,
    double? coverScale,
    bool? coverShadow,
    bool? squareCoverRadius,
    double? bgBlur,
    double? bgDim,
    double? lyricFontSize,
    double? lyricLineGap,
    NpLyricAlign? lyricAlign,
    bool? showTranslation,
    double? lyricFade,
    double? lyricBlur,
    Color? yrcPlayed,
    Color? yrcUnplayed,
    double? animationSpeed,
    MiniPlayerStyle? miniStyle,
  }) {
    return NpPlayerSettings(
      displayMode: displayMode ?? this.displayMode,
      hidePlayerControls: hidePlayerControls ?? this.hidePlayerControls,
      coverStyle: coverStyle ?? this.coverStyle,
      coverScale: coverScale ?? this.coverScale,
      coverShadow: coverShadow ?? this.coverShadow,
      squareCoverRadius: squareCoverRadius ?? this.squareCoverRadius,
      bgBlur: bgBlur ?? this.bgBlur,
      bgDim: bgDim ?? this.bgDim,
      lyricFontSize: lyricFontSize ?? this.lyricFontSize,
      lyricLineGap: lyricLineGap ?? this.lyricLineGap,
      lyricAlign: lyricAlign ?? this.lyricAlign,
      showTranslation: showTranslation ?? this.showTranslation,
      lyricFade: lyricFade ?? this.lyricFade,
      lyricBlur: lyricBlur ?? this.lyricBlur,
      yrcPlayed: yrcPlayed ?? this.yrcPlayed,
      yrcUnplayed: yrcUnplayed ?? this.yrcUnplayed,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      miniStyle: miniStyle ?? this.miniStyle,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        '_v': version,
        'displayMode': displayMode.name,
        'hidePlayerControls': hidePlayerControls,
        'coverStyle': coverStyle.name,
        'coverScale': coverScale,
        'coverShadow': coverShadow,
        'squareCoverRadius': squareCoverRadius,
        'bgBlur': bgBlur,
        'bgDim': bgDim,
        'lyricFontSize': lyricFontSize,
        'lyricLineGap': lyricLineGap,
        'lyricAlign': lyricAlign.name,
        'showTranslation': showTranslation,
        'lyricFade': lyricFade,
        'lyricBlur': lyricBlur,
        'yrcPlayed': yrcPlayed.toARGB32(),
        'yrcUnplayed': yrcUnplayed.toARGB32(),
        'animationSpeed': animationSpeed,
        'miniStyle': miniStyle.name,
      };

  factory NpPlayerSettings.fromMap(Map<Object?, Object?> map) {
    double clampD(Object? v, double min, double max, double fallback) {
      if (v is num) return (v.toDouble()).clamp(min, max);
      return fallback;
    }

    Color colorOf(Object? v, Color fallback) => v is int ? Color(v) : fallback;

    return NpPlayerSettings(
      displayMode: NpDisplayMode.values.firstWhere(
        (NpDisplayMode m) => m.name == map['displayMode'],
        orElse: () => NpDisplayMode.both,
      ),
      hidePlayerControls: map['hidePlayerControls'] == true,
      coverStyle: NpCoverStyle.values.firstWhere(
        (NpCoverStyle s) => s.name == map['coverStyle'],
        orElse: () => NpCoverStyle.vinyl,
      ),
      coverScale: clampD(map['coverScale'], 0.70, 1.20, defaults.coverScale),
      coverShadow: map['coverShadow'] is bool
          ? map['coverShadow']! as bool
          : defaults.coverShadow,
      squareCoverRadius: map['squareCoverRadius'] is bool
          ? map['squareCoverRadius']! as bool
          : defaults.squareCoverRadius,
      miniStyle: MiniPlayerStyle.values.firstWhere(
        (MiniPlayerStyle s) => s.name == map['miniStyle'],
        orElse: () => defaults.miniStyle,
      ),
      bgBlur: clampD(map['bgBlur'], 0, 40, defaults.bgBlur),
      bgDim: clampD(map['bgDim'], 0, 100, defaults.bgDim),
      lyricFontSize:
          clampD(map['lyricFontSize'], 12, 40, defaults.lyricFontSize),
      lyricLineGap: clampD(map['lyricLineGap'], 8, 48, defaults.lyricLineGap),
      lyricAlign: NpLyricAlign.values.firstWhere(
        (NpLyricAlign a) => a.name == map['lyricAlign'],
        orElse: () => NpLyricAlign.left,
      ),
      showTranslation: map['showTranslation'] is bool
          ? map['showTranslation']! as bool
          : defaults.showTranslation,
      lyricFade: clampD(map['lyricFade'], 0, 1, defaults.lyricFade),
      lyricBlur: clampD(map['lyricBlur'], 0, 10, defaults.lyricBlur),
      yrcPlayed: colorOf(map['yrcPlayed'], defaults.yrcPlayed),
      yrcUnplayed: colorOf(map['yrcUnplayed'], defaults.yrcUnplayed),
      animationSpeed:
          clampD(map['animationSpeed'], 0.5, 2.0, defaults.animationSpeed),
    );
  }

  /// 供 AnimatedSwitcher / 测试断言使用
  Object get identityKey => toMap().toString();
}
