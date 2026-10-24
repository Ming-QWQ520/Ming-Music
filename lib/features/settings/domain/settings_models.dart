/// 设置域模型：背景系统配置 / 液态玻璃偏好 / 网易云音质等级。
library;

/// 背景系统类型（需求：播放页去除纯色渐变，改为流体背景）
enum BackgroundType { blurCover, fluid, image }

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
        BackgroundType.fluid => 'fluid',
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
      // 需求：纯色渐变已移除 —— 历史 gradient 值统一迁移为流体背景
      type: switch (typeName) {
        'blurCover' => BackgroundType.blurCover,
        'image' => BackgroundType.image,
        _ => BackgroundType.fluid,
      },
      gradientIndex: map['gradientIndex'] as int? ?? 0,
      imagePath: map['imagePath'] as String?,
    );
  }
}

/// 液态玻璃偏好：auto 跟随设备能力（Android 12+ 启用）
enum GlassPref { auto, on, off }

/// 我的页歌单排列方式（需求：宫格/列表可切换，默认宫格；
/// 宫格下收藏的歌单不显示收起/弹出栏，直接续排在最后一个创建的歌单下方）
enum LibraryPlaylistLayout { grid, list }

extension LibraryPlaylistLayoutX on LibraryPlaylistLayout {
  String get label => switch (this) {
        LibraryPlaylistLayout.grid => '宫格',
        LibraryPlaylistLayout.list => '列表',
      };
}

extension GlassPrefX on GlassPref {
  String get label => switch (this) {
        GlassPref.auto => '自动',
        GlassPref.on => '开启',
        GlassPref.off => '关闭',
      };
}

/// 液态玻璃的自动降级判定阈值。
///
/// 需求修复（荣耀 LRA-AL00 / Android 10 实测）：旧值 31 (Android 12) 使
/// Android 10 设备全部降级为 0.88+ 高不透明实底 —— 底部导航栏与经典
/// Mini 条"不透明、周围黑边"。本应用已强制 Skia+GLES 渲染路径，且
/// BackdropFilter 仅用于导航栏/Mini 条/底部 Sheet（性能红线内），
/// RenderEffect 缺失时 Skia 仍可软件路径执行（模糊半径 ≤ 22 无可感知
/// 掉帧）。阈值下调到 27（Android 8.1），用户仍可在设置中手动关闭。
const int kGlassAutoMinSdk = 27;

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
