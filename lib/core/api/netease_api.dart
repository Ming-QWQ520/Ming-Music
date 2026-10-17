/// 网易云音乐 API 客户端（musicapi.mingqwq.top / NeteaseCloudMusicAPI Enhanced）。
///
/// 设计要点：
///  - 零第三方网络依赖：基于 dart:io HttpClient，可控超时与重试；
///  - 游客凭证：首次请求前调用 `/register/anonimous` 获取游客 cookie 并
///    持久化，避免部分接口未登录报 301/400（文档「游客登录」节）；
///  - 防缓存：服务端对相同 URL 有 2 分钟缓存，每次请求附加 timestamp；
///  - 服务偶发抖动（冷启动/风控限流）：统一 15s 超时 + 1 次重试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/prefs_keys.dart';

/// API 业务异常（非 200 响应 / 网络失败）
class ApiException implements Exception {
  ApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() =>
      code == null ? 'ApiException: $message' : 'ApiException($code): $message';
}

class NeteaseApi {
  NeteaseApi(this._prefs);

  static const String baseUrl = 'https://musicapi.mingqwq.top';

  /// 连接与总响应超时：服务偶发慢查询，取宽松值并配合重试
  static const Duration _timeout = Duration(seconds: 15);

  final SharedPreferences _prefs;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  String? _anonCookie;

  /// 统一 GET：自动附带游客 cookie 与时间戳，返回解码后的 JSON 对象。
  Future<Map<String, Object?>> get(
    String path,
    Map<String, String> params,
  ) async {
    final Map<String, String> query = Map<String, String>.of(params);
    final String? cookie = await _anonymousCookie();
    if (cookie != null) query['cookie'] = cookie;
    // 服务端 2 分钟缓存：时间戳防缓存（文档「调用前须知」）
    query['timestamp'] = DateTime.now().millisecondsSinceEpoch.toString();

    final StringBuffer sb = StringBuffer('$baseUrl$path?');
    query.forEach((String k, String v) {
      sb.write('${Uri.encodeQueryComponent(k)}='
          '${Uri.encodeQueryComponent(v)}&');
    });
    final String url = sb.toString().substring(0, sb.length - 1);

    Object? decoded;
    // 1 次重试：抖动场景下显著提高成功率
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        decoded = await _getJson(url);
        break;
      } on TimeoutException {
        if (attempt == 1) rethrow;
      } on SocketException {
        if (attempt == 1) rethrow;
      } on HttpException {
        if (attempt == 1) rethrow;
      } catch (_) {
        rethrow; // 解析错误等不可恢复异常直接抛出
      }
    }

    if (decoded is! Map<String, Object?>) {
      throw ApiException('接口返回格式异常: $path');
    }
    final Object? code = decoded['code'];
    // 301 = 未登录（游客拿不到该资源），301/400 统一归为业务错误
    if (code is int && code != 200) {
      throw ApiException('接口返回错误 $code', code: code);
    }
    return decoded;
  }

  Future<Object?> _getJson(String url) async {
    final HttpClientRequest request = await _client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final HttpClientResponse response = await request.close().timeout(_timeout);
    if (response.statusCode != 200) {
      await response.drain<Object?>();
      throw ApiException(
        'HTTP ${response.statusCode}',
        code: response.statusCode,
      );
    }
    final String body =
        await response.transform(utf8.decoder).join().timeout(_timeout);
    return jsonDecode(body);
  }

  /// 游客 cookie（MUSIC_U）：内存 → 磁盘 → 远程获取。
  /// 获取失败不阻塞请求（多数浏览接口匿名可用）。
  Future<String?> _anonymousCookie() async {
    if (_anonCookie != null) return _anonCookie;
    final String? saved = _prefs.getString(PrefsKeys.anonCookie);
    if (saved != null && saved.isNotEmpty) {
      _anonCookie = saved;
      return saved;
    }
    try {
      final Object? decoded = await _getJson(
        '$baseUrl/register/anonimous?timestamp='
        '${DateTime.now().millisecondsSinceEpoch}',
      );
      if (decoded is Map<String, Object?>) {
        final String? raw = decoded['cookie'] as String?;
        final String? musicU = _extractMusicU(raw);
        if (musicU != null) {
          _anonCookie = musicU;
          await _prefs.setString(PrefsKeys.anonCookie, musicU);
        }
      }
    } catch (e) {
      debugPrint('游客登录失败（继续匿名请求）: $e');
    }
    return _anonCookie;
  }

  /// 从 set-cookie 串中提取 `MUSIC_U=值`（到第一个分号）
  static String? _extractMusicU(String? raw) {
    if (raw == null) return null;
    final RegExpMatch? m = RegExp(r'MUSIC_U=([^;]+)').firstMatch(raw);
    return m == null ? null : 'MUSIC_U=${m.group(1)!}';
  }
}
