/// 设置域模型：背景系统配置 / 播放页模块布局 / 液态玻璃偏好。
library;

/// 背景系统类型
enum BackgroundType { blurCover, gradient, image }

/// 背景系统配置（持久化到 SharedPreferences）
class BackgroundConfig {
  const BackgroundConfig({
    this.type = BackgroundType.blurCover,
    this.gradientIndex = 0,
    this.imagePath,
  });

  static const BackgroundConfig defaults = BackgroundConfig();

  final BackgroundType type;

  /// 渐变预设下标（kGradientPresets）
  final int gradientIndex;

  /// 自定义背景图片的持久化文件路径
  final String? imagePath;

  /// 用于 AnimatedSwitcher 的 ValueKey：任一维度变化即触发平滑过渡
  Object get identityKey => switch (type) {
        BackgroundType.blurCover => 'blurCover',
        BackgroundType.gradient => 'gradient-$gradientIndex',
        BackgroundType.image => 'image-${imagePath ?? 'none'}',
      };

  BackgroundConfig copyWith({
    BackgroundType? type,
    int? gradientIndex,
    String? imagePath,
    bool clearImage = false,
  }) {
    return BackgroundConfig(
      type: type ?? this.type,
      gradientIndex: gradientIndex ?? this.gradientIndex,
      imagePath: clearImage ? null : (imagePath ?? this.imagePath),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'type': type.name,
        'gradientIndex': gradientIndex,
        'imagePath': imagePath,
      };

  factory BackgroundConfig.fromMap(Map<Object?, Object?> map) {
    final String typeName = map['type'] as String? ?? 'blurCover';
    return BackgroundConfig(
      type: BackgroundType.values.firstWhere(
        (BackgroundType t) => t.name == typeName,
        orElse: () => BackgroundType.blurCover,
      ),
      gradientIndex: map['gradientIndex'] as int? ?? 0,
      imagePath: map['imagePath'] as String?,
    );
  }
}

/// 播放页模块（DIY 拖拽重排的最小单元）
enum PlayerModule { cover, lyrics, progress, controls }

extension PlayerModuleX on PlayerModule {
  String get label => switch (this) {
        PlayerModule.cover => '旋转封面',
        PlayerModule.lyrics => '滚动歌词',
        PlayerModule.progress => '进度条',
        PlayerModule.controls => '控制栏',
      };

  /// 手机端单列布局中的弹性权重
  int get flex => switch (this) {
        PlayerModule.cover => 44,
        PlayerModule.lyrics => 36,
        PlayerModule.progress => 7,
        PlayerModule.controls => 13,
      };
}

/// 播放页模块布局配置（序列化保存到本地）
class LayoutConfig {
  const LayoutConfig(this.modules);

  static const LayoutConfig defaults = LayoutConfig(<PlayerModule>[
    PlayerModule.cover,
    PlayerModule.lyrics,
    PlayerModule.progress,
    PlayerModule.controls,
  ]);

  final List<PlayerModule> modules;

  /// 归一化：去重 + 补全四个模块，避免脏数据破坏 UI
  List<PlayerModule> get normalized {
    final List<PlayerModule> seen = <PlayerModule>[];
    for (final PlayerModule m in modules) {
      if (!seen.contains(m)) seen.add(m);
    }
    for (final PlayerModule m in PlayerModule.values) {
      if (!seen.contains(m)) seen.add(m);
    }
    return seen;
  }

  LayoutConfig copyWith(List<PlayerModule> modules) => LayoutConfig(modules);

  Map<String, Object?> toMap() => <String, Object?>{
        'modules': modules.map((PlayerModule m) => m.name).toList(),
      };

  factory LayoutConfig.fromMap(Map<Object?, Object?> map) {
    final List<dynamic> raw = map['modules'] as List<dynamic>? ?? <dynamic>[];
    return LayoutConfig(
      raw
          .map((dynamic e) => PlayerModule.values.firstWhere(
                (PlayerModule m) => m.name == e,
                orElse: () => PlayerModule.cover,
              ))
          .toList(),
    );
  }
}

/// 液态玻璃偏好：auto 跟随设备能力（Android 12+ 启用）
enum GlassPref { auto, on, off }

extension GlassPrefX on GlassPref {
  String get label => switch (this) {
        GlassPref.auto => '自动',
        GlassPref.on => '开启',
        GlassPref.off => '关闭',
      };
}

/// 液态玻璃的自动降级判定阈值：Android 12 (SDK 31) 起
/// BackdropFilter 的 blur 有 RenderEffect 硬件加速，代价显著更低。
const int kGlassAutoMinSdk = 31;
