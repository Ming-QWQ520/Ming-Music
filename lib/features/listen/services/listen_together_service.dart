/// 一起听（实验性 Beta）—— 局域网播放同步服务。
///
/// 无需服务端支持：主设备内置 HttpServer（端口 28895 起，占用则向上探测），
/// 客人设备通过 HTTP 轮询跟随播放状态（歌曲/进度/播放暂停）。
///
/// 协议：
///   GET /ping   → {app:'ming-music', room:'listen-together', listeners:n,
///                  title, artist}
///   GET /state  → {songId,title,artist,cover,positionMs,isPlaying,ts}
///
/// 同步策略（客人端）：
///   - 歌曲变化 → playSongs（neteaseId 解析直链，队列替换为单曲）；
///   - 进度偏差 > 3.5s → seek；
///   - 播放状态不一致 → play/pause。
///
/// ⚠️ Beta 限制：需要两台设备接入同一 Wi-Fi；网易云 VIP 歌曲在客人端
/// 需自行具备播放权限；断线自动提示。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class ListenState {
  const ListenState({
    this.songId = 0,
    this.title = '',
    this.artist = '',
    this.cover = '',
    this.positionMs = 0,
    this.isPlaying = false,
    this.ts = 0,
  });

  final int songId;
  final String title;
  final String artist;
  final String cover;
  final int positionMs;
  final bool isPlaying;
  final int ts;

  Map<String, Object?> toMap() => <String, Object?>{
        'songId': songId,
        'title': title,
        'artist': artist,
        'cover': cover,
        'positionMs': positionMs,
        'isPlaying': isPlaying,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };

  static ListenState fromMap(Object? raw) {
    if (raw is! Map<String, Object?>) return const ListenState();
    return ListenState(
      songId: (raw['songId'] as num?)?.toInt() ?? 0,
      title: (raw['title'] as String?) ?? '',
      artist: (raw['artist'] as String?) ?? '',
      cover: (raw['cover'] as String?) ?? '',
      positionMs: (raw['positionMs'] as num?)?.toInt() ?? 0,
      isPlaying: raw['isPlaying'] == true,
      ts: (raw['ts'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 主机：状态供给器（每次 /state 请求实时读取）
typedef ListenStateSupplier = ListenState Function();

/// 一起听同步服务（主机 = HttpServer；客人 = 轮询客户端）
class ListenTogetherService {
  ListenTogetherService();

  static const int kBasePort = 28895;
  static const int kPortProbeRange = 10;
  static const Duration kPollInterval = Duration(milliseconds: 1400);

  HttpServer? _server;
  ListenStateSupplier? _supplier;
  final Set<String> _listeners = <String>{};

  bool get isHosting => _server != null;
  int get port => _server?.port ?? 0;
  Set<String> get listeners => Set<String>.of(_listeners);

  /// 本机局域网 IPv4 列表（供邀请文案使用）
  static Future<List<String>> localIps() async {
    final List<String> out = <String>[];
    try {
      final List<NetworkInterface> interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final NetworkInterface itf in interfaces) {
        for (final InternetAddress addr in itf.addresses) {
          if (!addr.isLoopback) out.add(addr.address);
        }
      }
    } catch (_) {}
    return out;
  }

  // ---------------------------------------------------------------- 主机

  /// 启动主机房间。返回端口（失败抛异常）。
  Future<int> startHosting(ListenStateSupplier supplier) async {
    await stop();
    _supplier = supplier;
    Object? lastError;
    for (int i = 0; i < kPortProbeRange; i++) {
      try {
        _server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          kBasePort + i,
          shared: true,
        );
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (_server == null) {
      throw Exception('端口占用，无法启动一起听房间：$lastError');
    }
    _server!.listen(_handleRequest, onError: (Object e) {
      debugPrint('listen-together server error: $e');
    });
    return _server!.port;
  }

  Future<void> stop() async {
    _server?.close(force: true);
    _server = null;
    _supplier = null;
    _listeners.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    _client?.close(force: true);
    _client = null;
    _lastState = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final String ip = req.connectionInfo?.remoteAddress.address ?? '未知';
      switch (req.uri.path) {
        case '/ping':
          _listeners.add(ip);
          final ListenState s = _supplier?.call() ?? const ListenState();
          _reply(req, <String, Object?>{
            'app': 'ming-music',
            'room': 'listen-together',
            'listeners': _listeners.length,
            'title': s.title,
            'artist': s.artist,
          });
        case '/state':
          _listeners.add(ip);
          final ListenState s = _supplier?.call() ?? const ListenState();
          _reply(req, s.toMap());
        default:
          req.response.statusCode = 404;
          await req.response.close();
      }
    } catch (e) {
      debugPrint('listen-together handle error: $e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  void _reply(HttpRequest req, Map<String, Object?> data) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }

  // ---------------------------------------------------------------- 客人

  Timer? _pollTimer;
  HttpClient? _client;
  ListenState? _lastState;
  DateTime _lastSyncAt = DateTime.fromMillisecondsSinceEpoch(0);

  ListenState? get lastState => _lastState;
  bool get isJoined => _pollTimer != null;

  /// 距上次成功同步的时长（断线判定用）
  Duration get sinceLastSync => DateTime.now().difference(_lastSyncAt);

  /// 远端状态回调（页面注册：执行播放跟随）
  void Function(ListenState state)? onRemoteState;

  /// 加入房间（校验 /ping 后开始轮询 /state）
  Future<void> join(String host, int port) async {
    await stop();
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final Map<String, Object?>? ping = await _getJson(host, port, '/ping');
    if (ping == null || ping['room'] != 'listen-together') {
      await stop();
      throw Exception('未发现一起听房间（请确认同一 Wi-Fi 与端口）');
    }
    _pollTimer = Timer.periodic(kPollInterval, (_) => _poll(host, port));
    await _poll(host, port);
  }

  Future<void> _poll(String host, int port) async {
    final Map<String, Object?>? raw = await _getJson(host, port, '/state');
    if (raw == null) return;
    final ListenState s = ListenState.fromMap(raw);
    _lastState = s;
    _lastSyncAt = DateTime.now();
    onRemoteState?.call(s);
  }

  Future<Map<String, Object?>?> _getJson(
      String host, int port, String path) async {
    final HttpClient? client = _client;
    if (client == null) return null;
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse('http://$host:$port$path'))
            ..headers.set(HttpHeaders.userAgentHeader, 'MingMusic-Listen/1.0');
      final HttpClientResponse resp =
          await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final String body = await resp.transform(utf8.decoder).join();
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
