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

/// Mini 播放条样式（需求：预设只保留「经典条」与「紧凑极简」，
/// 其余样式全部移除；两种样式均带液态玻璃底）
enum MiniPlayerStyle {
  /// 经典条（仿参考图）：深蓝液态玻璃圆角长条 —— 左圆形封面 +
  /// 「歌名 - 歌手」+ 进度圆环播放键 + 播放列表键
  classic,

  /// 紧凑极简：嵌入导航栏，仅封面（圆环进度绕封面），无文字
  compact,
}

extension MiniPlayerStyleX on MiniPlayerStyle {
  String get label => switch (this) {
        MiniPlayerStyle.classic => '经典条',
        MiniPlayerStyle.compact => '紧凑极简',
      };
}

/// 封面样式（需求：只保留「正方形」与「正方形带圆角」，圆形/黑胶
/// 等其它样式全部移除；默认为方形圆角）
enum NpCoverStyle { square, rounded }

extension NpCoverStyleX on NpCoverStyle {
  String get label => switch (this) {
        NpCoverStyle.square => '正方形',
        NpCoverStyle.rounded => '方形圆角',
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

/// 底部功能条按钮 id（「播放页底部功能自定义」面板可勾选显隐 +
/// 拖动自定义顺序）。需求：新增「音量条」按键 —— 勾选后播放页底部
/// 只保留音量条与设置键（音量条在设置键左侧，样式与进度条一致）。
const List<String> kStripButtonIds = <String>[
  'volume', // 音量条（勾选后独占模式：音量条 + 设置）
  'output', // 媒体输出
  'similar', // 相似歌曲
  'wiki', // 歌词百科
  'download', // 下载
  'comments', // 评论
  'settings', // 设置
];

const List<String> kStripButtonDefaults = <String>[
  'output',
  'similar',
  'wiki',
  'settings',
];

String stripButtonLabel(String id) => switch (id) {
      'volume' => '音量条',
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
    // 需求：封面默认样式为方形圆角
    this.coverStyle = NpCoverStyle.rounded,
    this.coverScale = 1.0,
    this.coverShadow = true,
    this.bgBlur = 25,
    this.bgDim = 75,
    // 需求：歌词默认字号 20px
    this.lyricFontSize = 20,
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
    this.playerKeepScreenOn = false,
    this.miniStyle = MiniPlayerStyle.classic,
    // 需求：Mini 条无色 65% 透明（miniColor=null = 无色白玻璃；
    // miniTransparency = 透明度百分比 0.20-0.95，默认 0.65，填充
    // 不透明度 = 1 - 透明度）；可在设置中自定义颜色与透明度
    this.miniColor,
    this.miniTransparency = 0.65,
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

  /// Mini 播放条样式
  final MiniPlayerStyle miniStyle;

  /// Mini 条自定义底色（ARGB；null = 无色 —— 白色玻璃中性底，需求默认）
  final int? miniColor;

  /// Mini 条透明度（0.20 - 0.95；需求默认 0.65 = 65% 透明）
  final double miniTransparency;

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

  /// 播放页始终亮屏（需求：设置中可开启，进入播放页保持屏幕常亮）
  final bool playerKeepScreenOn;

  /// 播放页底部功能条按钮（有序 id 列表，来自 kStripButtonIds）
  final List<String> stripButtons;

  NpPlayerSettings copyWith({
    NpDisplayMode? displayMode,
    NpCoverStyle? coverStyle,
    double? coverScale,
    bool? coverShadow,
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
    bool? playerKeepScreenOn,
    MiniPlayerStyle? miniStyle,
    int? miniColor,
    bool clearMiniColor = false,
    double? miniTransparency,
    List<String>? stripButtons,
  }) {
    return NpPlayerSettings(
      displayMode: displayMode ?? this.displayMode,
      coverStyle: coverStyle ?? this.coverStyle,
      coverScale: coverScale ?? this.coverScale,
      coverShadow: coverShadow ?? this.coverShadow,
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
      playerKeepScreenOn: playerKeepScreenOn ?? this.playerKeepScreenOn,
      miniStyle: miniStyle ?? this.miniStyle,
      miniColor: clearMiniColor ? null : (miniColor ?? this.miniColor),
      miniTransparency: miniTransparency ?? this.miniTransparency,
      stripButtons: stripButtons ?? this.stripButtons,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        '_v': version,
        'displayMode': displayMode.name,
        'coverStyle': coverStyle.name,
        'coverScale': coverScale,
        'coverShadow': coverShadow,
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
        'playerKeepScreenOn': playerKeepScreenOn,
        'miniStyle': miniStyle.name,
        'miniColor': miniColor,
        'miniTransparency': miniTransparency,
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
      // 版本迁移（需求：封面只保留正方形/方形圆角）——
      // 历史 circle（圆形）/黑胶等旧值统一回退方形圆角
      coverStyle: switch (map['coverStyle']) {
        'square' => NpCoverStyle.square,
        'rounded' => NpCoverStyle.rounded,
        _ => NpCoverStyle.rounded,
      },
      coverScale: clampD(map['coverScale'], 0.70, 1.20, defaults.coverScale),
      coverShadow: map['coverShadow'] is bool
          ? map['coverShadow']! as bool
          : defaults.coverShadow,
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
      playerKeepScreenOn: map['playerKeepScreenOn'] == true,
      miniStyle: MiniPlayerStyle.values.firstWhere(
        (MiniPlayerStyle s) => s.name == map['miniStyle'],
        orElse: () => defaults.miniStyle,
      ),
      miniColor: map['miniColor'] is int ? map['miniColor']! as int : null,
      miniTransparency:
          clampD(map['miniTransparency'], 0.20, 0.95, defaults.miniTransparency),
      stripButtons:
          strip.isEmpty ? List<String>.of(kStripButtonDefaults) : strip,
    );
  }

  /// 供 AnimatedSwitcher / 测试断言使用
  Object get identityKey => toMap().toString();
}
