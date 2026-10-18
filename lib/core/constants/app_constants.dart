/// 全局常量：阈值、周期、预设均集中于此，禁止在 UI 中写死魔法数字。
library;

import 'package:flutter/material.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'MingMusic';
  static const String appVersion = '1.1.0';
  static const String repoUrl = 'https://github.com/Ming-QWQ520/Ming-Music';

  /// 网易云 API 域名（文档：https://musicapi.mingqwq.top/docs/）
  static const String apiBaseUrl = 'https://musicapi.mingqwq.top';

  /// 响应式断点：>= 600dp 视为平板/横屏大屏布局
  static const double wideBreakpoint = 600;

  /// 手势避让：左右边缘各留 20px 给系统侧滑返回（避坑指南 4）
  static const double gestureEdgeExclusion = 20;

  /// 播放页下滑收起的判定阈值
  static const double dismissDragThreshold = 130;
  static const double dismissVelocityThreshold = 750;

  /// 黑胶唱片旋转周期
  static const Duration rotationPeriod = Duration(seconds: 20);

  /// 播放页左右翻页（唱片/歌词）动画时长
  static const Duration playerPageFlip = Duration(milliseconds: 320);

  /// 左右滑动切歌：拖动跟手视差最大偏移 px
  static const double swipeParallaxMax = 48;

  /// 逐字歌词行高
  static const double yrcLineExtent = 58;

  /// 逐行歌词（LRC 回退）行高
  static const double lyricLineExtent = 64;

  /// 用户手动滚动歌词后，自动滚动暂停时长
  static const Duration lyricScrollSuppression = Duration(seconds: 4);

  /// audio_service 通知渠道
  static const String notificationChannelId = 'com.ming.music.playback';

  /// 主品牌色（对齐参考图：网易云红）
  static const Color brandColor = Color(0xFFEC4141);

  /// 深色界面基底
  static const Color darkScaffold = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
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
