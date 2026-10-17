/// 设置域模型：背景系统配置 / 液态玻璃偏好 / 网易云音质等级。
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

/// 网易云播放音质等级（对应 /song/url/v1 的 level 参数）
enum AudioQuality { standard, higher, exhigh, lossless }

extension AudioQualityX on AudioQuality {
  String get label => switch (this) {
        AudioQuality.standard => '标准 (128K)',
        AudioQuality.higher => '较高 (192K)',
        AudioQuality.exhigh => '极高 (320K)',
        AudioQuality.lossless => '无损 FLAC',
      };

  String get apiValue => name;

  static AudioQuality fromName(String? name) => AudioQuality.values.firstWhere(
        (AudioQuality q) => q.name == name,
        orElse: () => AudioQuality.standard,
      );
}
