/// 平台动作桥（MethodChannel 封装）：分享 / 外链 / 音频下载 / 本地音乐扫描 /
/// 输出路由。所有方法失败静默返回失败值，绝不抛异常打断 UI 流程。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class PlatformActions {
  PlatformActions._();

  static const MethodChannel _channel = MethodChannel('com.ming.music/media');

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
      final Object? raw = await _channel.invokeMethod<Object?>('getLocalAudioFiles');
      if (raw is! List<Object?>) return const <Map<String, Object?>>[];
      return raw.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) {
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
      return raw.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) {
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

  /// 下载网络文件字节（简单重试 1 次）
  static Future<Uint8List?> downloadBytes(String url) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final HttpClient client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        final HttpClientRequest req = await client.getUrl(Uri.parse(url));
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
