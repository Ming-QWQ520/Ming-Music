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

  /// 登录用户 cookie（MUSIC_U=...，由二维码/手机登录成功后写入）
  String? _userCookie;

  /// 登录用户 cookie 是否存在（用于 UI 判定与请求附加）
  bool get hasUserCookie => _userCookie != null;

  /// 恢复登录态：由 AuthNotifier 启动时调用
  void restoreUserCookie(String? cookie) {
    _userCookie = (cookie == null || cookie.isEmpty) ? null : cookie;
  }

  void setUserCookie(String cookie) {
    _userCookie = cookie;
    _prefs.setString(PrefsKeys.userCookie, cookie);
  }

  void clearUserCookie() {
    _userCookie = null;
    _prefs.remove(PrefsKeys.userCookie);
  }

  /// 读取当前生效 cookie（用户登录态优先，游客兜底）
  Future<String?> get effectiveCookie async =>
      _userCookie ?? await _anonymousCookie();

  /// 统一 GET：自动附带 cookie（登录态优先）与时间戳，返回解码后的 JSON 对象。
  ///
  /// [allowedCodes]：除 200 外视为成功的业务码（如二维码轮询的 800/801/802/803）。
  /// [throwOnCode]：为 false 时不因 code != 200 抛异常，交调用方自行处理
  /// （登录/评论写操作需要展示服务端 message）。
  Future<Map<String, Object?>> get(
    String path,
    Map<String, String> params, {
    Set<int>? allowedCodes,
    bool throwOnCode = true,
  }) async =>
      _request(path, params,
          method: 'GET', allowedCodes: allowedCodes, throwOnCode: throwOnCode);

  /// 统一 POST（form-urlencoded，用于登录与评论写操作）
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> params, {
    bool throwOnCode = true,
  }) =>
      _request(path, params, method: 'POST', throwOnCode: throwOnCode);

  Future<Map<String, Object?>> _request(
    String path,
    Map<String, String> params, {
    required String method,
    Set<int>? allowedCodes,
    bool throwOnCode = true,
  }) async {
    final Map<String, String> payload = Map<String, String>.of(params);
    final String? cookie = await effectiveCookie;
    if (cookie != null) payload['cookie'] = cookie;
    // 服务端 2 分钟缓存：时间戳防缓存（文档「调用前须知」）
    payload['timestamp'] = DateTime.now().millisecondsSinceEpoch.toString();

    String url = '$baseUrl$path';
    String? body;
    if (method == 'GET') {
      final StringBuffer sb = StringBuffer('$url?');
      payload.forEach((String k, String v) {
        sb.write('${Uri.encodeQueryComponent(k)}='
            '${Uri.encodeQueryComponent(v)}&');
      });
      url = sb.toString().substring(0, sb.length - 1);
    } else {
      final StringBuffer sb = StringBuffer();
      payload.forEach((String k, String v) {
        sb.write('${Uri.encodeQueryComponent(k)}='
            '${Uri.encodeQueryComponent(v)}&');
      });
      body = sb.toString().substring(0, sb.length - 1);
    }

    Object? decoded;
    // 1 次重试：抖动场景下显著提高成功率
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        if (method == 'GET') {
          decoded = await _getJson(url);
        } else {
          decoded = await _postJson(url, body!);
        }
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
    if (code is int && code != 200) {
      final bool allowed = allowedCodes != null && allowedCodes.contains(code);
      if (!allowed && throwOnCode) {
        throw ApiException('接口返回错误 $code', code: code);
      }
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

  Future<Object?> _postJson(String url, String body) async {
    final HttpClientRequest request = await _client.postUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded; charset=utf-8');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.write(body);
    final HttpClientResponse response = await request.close().timeout(_timeout);
    if (response.statusCode != 200) {
      await response.drain<Object?>();
      throw ApiException(
        'HTTP ${response.statusCode}',
        code: response.statusCode,
      );
    }
    final String text =
        await response.transform(utf8.decoder).join().timeout(_timeout);
    return jsonDecode(text);
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

/// api-enhanced 兼容读取：部分接口返回 {code, data:{...}} 包裹层，
/// 部分直接平铺在顶层。统一先取 data 对象，缺省回退顶层。
Map<String, Object?> apiPayload(Map<String, Object?> res) {
  final Object? data = res['data'];
  if (data is Map<String, Object?>) return data;
  return res;
}
