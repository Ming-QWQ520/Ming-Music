/// 平台动作桥（MethodChannel 封装）：分享 / 外链 / 音频下载 / 本地音乐扫描 /
/// 输出路由。所有方法失败静默返回失败值，绝不抛异常打断 UI 流程。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../widgets/cover_image.dart';

class PlatformActions {
  PlatformActions._();

  static const MethodChannel _channel = MethodChannel('com.ming.music/media');

  /// 网络恢复事件通道（原生 ConnectivityManager：只在离线→在线转变时
  /// 发一次事件）。需求：无网播放失败/暂停后，联网自动接续播放。
  static const EventChannel _netEventChannel =
      EventChannel('com.ming.music/net');

  /// 单例广播流（重复订阅安全：EventChannel 每次 listen 重新注册原生回调）
  static Stream<dynamic>? _netStream;

  /// 网络恢复流（离线 → 在线 时 yield 一个事件）
  static Stream<dynamic> networkRestoredStream() =>
      _netStream ??= _netEventChannel.receiveBroadcastStream();

  /// 系统分享面板
  static Future<bool> shareText(String text) async {
    try {
      return await _channel.invokeMethod<bool>(
            'shareText',
            <String, String>{'text': text},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 打开外部链接
  static Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openUrl',
            <String, String>{'url': url},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 保存音频到 Music/MingMusic（下载歌曲 / 设为铃声素材）
  static Future<bool> saveAudio({
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    try {
      return await _channel.invokeMethod<bool>(
            'saveAudio',
            <String, Object?>{'name': name, 'mime': mime, 'bytes': bytes},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 本地音乐扫描（MediaStore 音频库）
  static Future<List<Map<String, Object?>>> localAudioFiles() async {
    try {
      final Object? raw =
          await _channel.invokeMethod<Object?>('getLocalAudioFiles');
      if (raw is! List<Object?>) return const <Map<String, Object?>>[];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) {
        return <String, Object?>{
          for (final MapEntry<Object?, Object?> e in m.entries)
            '${e.key}': e.value,
        };
      }).toList(growable: false);
    } catch (_) {
      return const <Map<String, Object?>>[];
    }
  }

  /// 输出设备列表（蓝牙 + 本机扬声器：name/type/id/bluetooth/speaker）
  static Future<List<Map<String, Object?>>> localOutputDevices() async {
    try {
      final Object? raw =
          await _channel.invokeMethod<Object?>('getMediaDevices');
      if (raw is! List<Object?>) return const <Map<String, Object?>>[];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) {
        return <String, Object?>{
          for (final MapEntry<Object?, Object?> e in m.entries)
            '${e.key}': e.value,
        };
      }).toList(growable: false);
    } catch (_) {
      return const <Map<String, Object?>>[];
    }
  }

  /// 输出设备切换：default=系统自动（蓝牙优先）/ speaker=扬声器 / bluetooth=蓝牙
  static Future<bool> setAudioOutput({
    required String mode,
    int? deviceId,
  }) async {
    try {
      return await _channel.invokeMethod<bool>(
            'setAudioOutput',
            <String, Object?>{'mode': mode, 'deviceId': deviceId},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 当前是否有可用网络（ConnectivityManager 实时状态，离线跳歌提示用）
  static Future<bool> isNetworkAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isNetworkAvailable') ?? true;
    } catch (_) {
      return true; // 探测失败按有网处理：宁可少提示不误报
    }
  }

  /// 发一条普通系统通知（需求：无网跳过未缓存歌曲时通知栏提示）。
  /// 使用独立轻量通道，与媒体通知互不干扰；失败静默。
  static Future<void> postStatusNotice({
    required String title,
    required String text,
  }) async {
    try {
      await _channel.invokeMethod<bool>(
        'postStatusNotice',
        <String, String>{'title': title, 'text': text},
      );
    } catch (_) {
      // 通知失败不影响播放流程
    }
  }

  /// 播放页屏幕常亮（需求：设置中「播放页始终亮屏」开关）。
  /// 原生 WindowManager FLAG_KEEP_SCREEN_ON，[on] false 恢复自动熄屏。
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod<bool>(
        'keepScreenOn',
        <String, bool>{'on': on},
      );
    } catch (_) {
      // 失败仅影响常亮功能本身
    }
  }

  /// 音频嗅探 MIME（按文件扩展名，服务端 type 优先）
  static String audioMimeOf(String? type, String url) {
    switch ((type ?? '').toLowerCase()) {
      case 'flac':
        return 'audio/flac';
      case 'ape':
        return 'audio/x-ape';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
      case 'aac':
        return 'audio/mp4a-latm';
    }
    final String lower = url.toLowerCase();
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.m4a')) return 'audio/mp4a-latm';
    return 'audio/mpeg';
  }

  /// 下载网络文件字节（简单重试 1 次）。
  /// 携带浏览器 UA：网易 CDN 对 Dart 默认 UA 返回 403（与封面同理）
  static Future<Uint8List?> downloadBytes(String url) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final HttpClient client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        final HttpClientRequest req = await client.getUrl(Uri.parse(url));
        req.headers
            .set(HttpHeaders.userAgentHeader, CoverImage.kImageUserAgent);
        final HttpClientResponse resp = await req.close().timeout(
              const Duration(seconds: 60),
            );
        if (resp.statusCode != 200) {
          await resp.drain<Object?>();
          continue;
        }
        final Uint8List bytes = Uint8List.fromList(
          await resp.fold<List<int>>(
            <int>[],
            (List<int> acc, List<int> chunk) => acc..addAll(chunk),
          ),
        );
        if (bytes.isNotEmpty) return bytes;
      } catch (_) {
        // 重试
      }
    }
    return null;
  }
}
