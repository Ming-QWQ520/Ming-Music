/// 播放页自定义设置（参考 Zephyr-Music PlayerSettings）：
///
///  - 显示模式（双列/仅封面/仅歌词）；
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

/// 封面样式（需求：去除黑胶样式，仅保留方形/圆形）
enum NpCoverStyle { square, circle }

extension NpCoverStyleX on NpCoverStyle {
  String get label => switch (this) {
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

/// 封面页歌词显示行数（需求：借鉴 kgka_Music_hl 封面页，默认一行）
enum NpCoverLyricsMode { none, one, two }

extension NpCoverLyricsModeX on NpCoverLyricsMode {
  String get label => switch (this) {
        NpCoverLyricsMode.none => '关闭',
        NpCoverLyricsMode.one => '一行',
        NpCoverLyricsMode.two => '两行',
      };
}

/// 底部功能条按钮 id（「播放页底部功能自定义」面板可勾选显隐）
const List<String> kStripButtonIds = <String>[
  'output',    // 媒体输出
  'similar',   // 相似歌曲
  'wiki',      // 歌词百科
  'download',  // 下载
  'comments',  // 评论
  'settings',  // 设置
];

const List<String> kStripButtonDefaults = <String>[
  'output', 'similar', 'wiki', 'settings',
];

String stripButtonLabel(String id) => switch (id) {
      'output' => '媒体输出',
      'similar' => '相似歌曲',
      'wiki' => '歌词百科',
      'download' => '下载',
      'comments' => '评论',
      'settings' => '设置',
      _ => id,
    };

class NpPlayerSettings {
  const NpPlayerSettings({
    this.displayMode = NpDisplayMode.both,
    this.coverStyle = NpCoverStyle.square,
    this.coverScale = 1.0,
    this.coverShadow = true,
    this.squareCoverRadius = false,
    this.bgBlur = 25,
    this.bgDim = 75,
    this.lyricFontSize = 17,
    this.lyricLineGap = 14,
    this.lyricAlign = NpLyricAlign.left,
    this.showTranslation = true,
    this.lyricFade = 0.55,
    this.lyricBlur = 0,
    this.yrcPlayed = const Color(0xFFFFFFFF),
    this.yrcUnplayed = const Color(0x66FFFFFF),
    this.highlightPlayed = false,
    this.lyricAlwaysCenter = false,
    this.coverLyrics = NpCoverLyricsMode.one,
    this.heartEffect = true,
    this.showMvBadge = true,
    this.miniStyle = MiniPlayerStyle.classic,
    this.stripButtons = kStripButtonDefaults,
  });

  static const int version = 1;

  static const NpPlayerSettings defaults = NpPlayerSettings();

  // ---- 显示 ----

  /// 显示模式（平板双列 / 锁定单视图）
  final NpDisplayMode displayMode;

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

  /// 背景模糊强度 px（0 - 40；需求默认 25）
  final double bgBlur;

  /// 背景变暗 %（0 - 100；需求默认 75）
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

  /// 高亮已播放歌词（关 = 只高亮当前播放行/字，已播放行不高亮；开 = 经典卡拉OK）
  final bool highlightPlayed;

  /// 歌词「时刻保持居中」（需求：并非无法拖动，而是让当前行始终位于可视区
  /// 中部；歌曲开头/结尾行不贴顶/贴底。拖动浏览不受影响，松手后恢复跟随）
  final bool lyricAlwaysCenter;

  /// 封面页歌词（需求：借鉴 kgka_Music_hl —— 封面下方显示当前行歌词，
  /// 可选 一行/两行，默认一行）
  final NpCoverLyricsMode coverLyrics;

  /// 红心动效（喜欢时心形迸发动画）
  final bool heartEffect;

  /// MV 徽标开关（需求：播放页歌名旁 MV 胶囊可开关显示，默认开启）
  final bool showMvBadge;

  /// 播放页底部功能条按钮（有序 id 列表，来自 kStripButtonIds）
  final List<String> stripButtons;

  NpPlayerSettings copyWith({
    NpDisplayMode? displayMode,
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
    bool? highlightPlayed,
    bool? lyricAlwaysCenter,
    NpCoverLyricsMode? coverLyrics,
    bool? heartEffect,
    bool? showMvBadge,
    MiniPlayerStyle? miniStyle,
    List<String>? stripButtons,
  }) {
    return NpPlayerSettings(
      displayMode: displayMode ?? this.displayMode,
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
      highlightPlayed: highlightPlayed ?? this.highlightPlayed,
      lyricAlwaysCenter: lyricAlwaysCenter ?? this.lyricAlwaysCenter,
      coverLyrics: coverLyrics ?? this.coverLyrics,
      heartEffect: heartEffect ?? this.heartEffect,
      showMvBadge: showMvBadge ?? this.showMvBadge,
      miniStyle: miniStyle ?? this.miniStyle,
      stripButtons: stripButtons ?? this.stripButtons,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        '_v': version,
        'displayMode': displayMode.name,
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
        'highlightPlayed': highlightPlayed,
        'lyricAlwaysCenter': lyricAlwaysCenter,
        'coverLyrics': coverLyrics.name,
        'heartEffect': heartEffect,
        'showMvBadge': showMvBadge,
        'miniStyle': miniStyle.name,
        'stripButtons': stripButtons,
      };

  factory NpPlayerSettings.fromMap(Map<Object?, Object?> map) {
    double clampD(Object? v, double min, double max, double fallback) {
      if (v is num) return (v.toDouble()).clamp(min, max);
      return fallback;
    }

    Color colorOf(Object? v, Color fallback) => v is int ? Color(v) : fallback;

    final List<String> strip = (map['stripButtons'] as List<Object?>?)
            ?.whereType<String>()
            .where((String id) => kStripButtonIds.contains(id))
            .toList() ??
        List<String>.of(kStripButtonDefaults);

    return NpPlayerSettings(
      displayMode: NpDisplayMode.values.firstWhere(
        (NpDisplayMode m) => m.name == map['displayMode'],
        orElse: () => NpDisplayMode.both,
      ),
      // 版本迁移：黑胶样式已移除（需求），历史值回退方形
      coverStyle: switch (map['coverStyle']) {
        'circle' => NpCoverStyle.circle,
        'square' => NpCoverStyle.square,
        _ => NpCoverStyle.square,
      },
      coverScale: clampD(map['coverScale'], 0.70, 1.20, defaults.coverScale),
      coverShadow: map['coverShadow'] is bool
          ? map['coverShadow']! as bool
          : defaults.coverShadow,
      squareCoverRadius: map['squareCoverRadius'] is bool
          ? map['squareCoverRadius']! as bool
          : defaults.squareCoverRadius,
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
      highlightPlayed: map['highlightPlayed'] == true,
      lyricAlwaysCenter: map['lyricAlwaysCenter'] == true,
      coverLyrics: NpCoverLyricsMode.values.firstWhere(
        (NpCoverLyricsMode m) => m.name == map['coverLyrics'],
        orElse: () => defaults.coverLyrics,
      ),
      heartEffect: map['heartEffect'] is bool
          ? map['heartEffect']! as bool
          : defaults.heartEffect,
      showMvBadge: map['showMvBadge'] is bool
          ? map['showMvBadge']! as bool
          : defaults.showMvBadge,
      miniStyle: MiniPlayerStyle.values.firstWhere(
        (MiniPlayerStyle s) => s.name == map['miniStyle'],
        orElse: () => defaults.miniStyle,
      ),
      stripButtons: strip.isEmpty ? List<String>.of(kStripButtonDefaults) : strip,
    );
  }

  /// 供 AnimatedSwitcher / 测试断言使用
  Object get identityKey => toMap().toString();
}
