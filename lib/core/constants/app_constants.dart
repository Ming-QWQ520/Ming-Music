/// 全局常量：阈值、周期、预设均集中于此，禁止在 UI 中写死魔法数字。
library;

import 'package:flutter/material.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'MingMusic';
  static const String appVersion = '1.0.0';
  static const String repoUrl = 'https://github.com/Ming-QWQ520/Ming-Music';

  /// 响应式断点：>= 600dp 视为平板/横屏大屏布局
  static const double wideBreakpoint = 600;

  /// 手势避让：左右边缘各留 20px 给系统侧滑返回（避坑指南 4）
  static const double gestureEdgeExclusion = 20;

  /// 封面旋转周期
  static const Duration rotationPeriod = Duration(seconds: 24);

  /// 液态玻璃模糊半径（仅局部使用，严禁全屏滥用 —— 避坑指南 2）
  static const double glassBlurSigma = 18;

  /// 播放页下滑收起的判定阈值
  static const double dismissDragThreshold = 130;
  static const double dismissVelocityThreshold = 750;

  /// 歌词行高（固定行高便于 animateTo 居中计算）
  static const double lyricLineExtent = 64;

  /// 用户手动滚动歌词后，自动滚动暂停时长
  static const Duration lyricScrollSuppression = Duration(seconds: 4);

  /// audio_service 通知渠道
  static const String notificationChannelId = 'com.ming.music.playback';

  /// 主品牌色
  static const Color brandColor = Color(0xFF8B7CF6);
}

/// 播放页背景渐变预设（Dart 3 Record）
typedef GradientPreset = ({String name, Color top, Color bottom});

const List<GradientPreset> kGradientPresets = [
  (name: '星夜紫', top: Color(0xFF1E1B4B), bottom: Color(0xFF7C3AED)),
  (name: '深海蓝', top: Color(0xFF0C2A4A), bottom: Color(0xFF0EA5E9)),
  (name: '暮霞粉', top: Color(0xFF4C0519), bottom: Color(0xFFFB7185)),
  (name: '翡翠绿', top: Color(0xFF022C22), bottom: Color(0xFF2DD4A7)),
  (name: '琥珀金', top: Color(0xFF451A03), bottom: Color(0xFFF5A623)),
];
