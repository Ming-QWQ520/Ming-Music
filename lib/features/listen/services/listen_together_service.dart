/// 一起听 —— 网易云官方「一起听」接口（第十三批需求：对齐
/// musicapi.mingqwq.top/listen_together_host.html 官方示例流程，
/// 替换旧局域网 HttpServer 方案 —— 官方接口不需要同一 Wi-Fi，
/// 两端登录网易云账号即可跨网络同步）。
///
/// 官方接口族（NeteaseCloudMusicApi Enhanced `listentogether/*`）：
///  - `POST /listentogether/room/create`        创建房间 → roomInfo.roomId
///    （账号已有房间时返回已存在的房间，官方语义）；
///  - `POST /listentogether/room/check`         房间校验/在线信息；
///  - `POST /listentogether/accept`             加入房间 {roomId, inviterId}；
///  - `POST /listentogether/sync/list/command`  队列公布 REPLACE（displayList/randomList）；
///  - `POST /listentogether/sync/playlist/get`  **读通路**：返回房间队列 +
///    playCommand（对方的操作命令 + serverSeq）；
///  - `POST /listentogether/play/command`       写通路：GOTO/PLAY/PAUSE/PROGRESS
///    + progress(ms) + targetSongId + clientSeq + playStatus；
///  - `POST /listentogether/heartbeat`          保活 {roomId, songId, playStatus, progress}；
///  - `POST /listentogether/status`             房间状态 + roomUsers[]；
///  - `POST /listentogether/end`                关闭房间。
///
/// 同步策略（对齐 Zephyr-Music/YunYin 实测经验）：
///  - 双端对称：房间内任何成员的换歌/播放暂停/拖动都会经 play/command
///    上报，其余成员轮询 sync/playlist/get 读取并应用；
///  - 以服务端 serverSeq 判定命令新旧（两端时钟不可靠，不用时间戳）；
///  - 命令类型分派：GOTO 无条件换歌；PLAY/PAUSE 只动播放状态；
///    PROGRESS/seek 只动进度 —— 播放暂停不靠位置差推断（官方 demo 的
///    'seek' 归一化为 PROGRESS 处理）；
///  - 进度是快照：应用时按「serverSeq 收到来_now」补流逝时间（仅播放中）；
///  - 防回环：应用对方命令后的短暂窗口内不上报本机推断的状态变化；
///  - 读通路只返回「对方」的命令：单人房间 sync/playlist/get 返回空
///    data，属于官方设计（自测需两个账号）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api/netease_api.dart';

/// 房间成员（/listentogether/status → roomInfo.roomUsers[]）
class ListenRoomUser {
  const ListenRoomUser({
    required this.userId,
    required this.nickname,
    this.avatarUrl = '',
  });

  final int userId;
  final String nickname;
  final String avatarUrl;

  static ListenRoomUser fromJson(Map<String, Object?> j) => ListenRoomUser(
        userId: (j['userId'] as num?)?.toInt() ?? 0,
        nickname: (j['nickname'] as String?) ?? '',
        avatarUrl: (j['avatarUrl'] as String?) ?? '',
      );
}

/// 房间内播放命令（sync/playlist/get → playCommand）
class ListenPlayCommand {
  const ListenPlayCommand({
    required this.userId,
    required this.commandType,
    required this.targetSongId,
    required this.progressMs,
    required this.playStatus,
    required this.serverSeq,
    required this.receivedAt,
  });

  final int userId;
  final String commandType;
  final int targetSongId;

  /// 命令发出时刻的播放进度快照（毫秒）
  final int progressMs;
  final String playStatus;
  final int serverSeq;

  /// 本机收到时刻（进度补流逝用）
  final DateTime receivedAt;

  /// 归一化类型：官方 demo 的 'seek' 与 YunYin 的 'PROGRESS' 同义
  bool get isSeek =>
      commandType == 'PROGRESS' || commandType.toLowerCase() == 'seek';
  bool get isGoto => commandType == 'GOTO';
  bool get isPlay => commandType == 'PLAY';
  bool get isPause => commandType == 'PAUSE';
}

/// 一起听官方接口服务（页面注册回调消费命令与房间状态）
class ListenTogetherService {
  ListenTogetherService(this._api);

  final NeteaseApi _api;

  String? _roomId;
  int _inviterId = 0;
  int _myUserId = 0;
  String _nickname = '';
  bool _isCreator = false;
  int _clientSeq = 1;

  /// 已应用的最大 serverSeq（旧命令幂等丢弃）
  int _lastAppliedSeq = 0;

  /// 防回环窗口截止时刻：应用对方命令后短时间内不上报本机状态
  DateTime _suppressReportUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  bool _polling = false;

  // ------------------------------------------------------------- getters

  bool get inRoom => _roomId != null;
  bool get isSyncing => _polling;
  String? get roomId => _roomId;
  int get inviterId => _inviterId;
  int get myUserId => _myUserId;
  String get nickname => _nickname;
  bool get isCreator => _isCreator;

  /// 防回环窗口是否生效（页面上报前检查）
  bool get reportSuppressed => DateTime.now().isBefore(_suppressReportUntil);

  /// 标记防回环窗口（应用对方命令后调用）
  void suppressReportFor(Duration duration) {
    _suppressReportUntil = DateTime.now().add(duration);
  }

  // ------------------------------------------------------------- 回调

  /// 对方命令（页面执行换歌/播放暂停/seek 跟随）
  void Function(ListenPlayCommand cmd)? onCommand;

  /// 房间状态刷新（在线成员变化）
  void Function(List<ListenRoomUser> users)? onRoomChanged;

  /// 非致命消息（轮询失败提示等）
  void Function(String message)? onNotice;

  /// 本机当前播放状态供给（heartbeat 上报用）
  ({int songId, bool playing, int progressMs}) Function()? statusSupplier;

  // ------------------------------------------------------------- 登录

  /// 确认网易云登录态（一起听强依赖登录）。
  /// 成功返回 null 并缓存 userId/nickname；否则返回错误文案。
  Future<String?> ensureLogin() async {
    try {
      final Map<String, Object?> res =
          await _api.get('/login/status', const <String, String>{});
      final Object? data = res['data'];
      final int code = data is Map<String, Object?>
          ? (data['code'] as num?)?.toInt() ?? 0
          : (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) return '请先登录网易云账号';
      final Object? profile =
          data is Map<String, Object?> ? data['profile'] : res['profile'];
      if (profile is! Map<String, Object?>) return '请先登录网易云账号';
      _myUserId = (profile['userId'] as num?)?.toInt() ?? 0;
      _nickname = (profile['nickname'] as String?) ?? '';
      if (_myUserId <= 0) return '请先登录网易云账号';
      return null;
    } catch (e) {
      return '登录状态获取失败：${_short(e)}';
    }
  }

  // ------------------------------------------------------------- 房间

  /// 创建房间（官方语义：已有房间时返回已存在的房间）。返回错误文案或 null。
  Future<String?> createRoom() async {
    final String? loginErr = await ensureLogin();
    if (loginErr != null) return loginErr;
    try {
      final Map<String, Object?> res = await _api
          .get('/listentogether/room/create', const <String, String>{});
      final Map<String, Object?> data = apiPayload(res);
      final Map<String, Object?>? roomInfo =
          (data['roomInfo'] ?? res['roomInfo']) as Map<String, Object?>?;
      final String? id = roomInfo?['roomId'] as String?;
      if (id == null || id.isEmpty) return '创建房间失败：响应缺少房间号';
      _roomId = id;
      _isCreator = true;
      _inviterId = _myUserId;
      _lastAppliedSeq = 0;
      return null;
    } catch (e) {
      return '创建房间失败：${_short(e)}';
    }
  }

  /// 加入房间（accept 需要房间号 + 邀请者 id 一对凭据）。返回错误文案或 null。
  Future<String?> joinRoom(String roomId, int inviterId) async {
    final String? loginErr = await ensureLogin();
    if (loginErr != null) return loginErr;
    final String rid = roomId.trim();
    if (rid.isEmpty) return '请输入邀请串（房间号|邀请人ID）';
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/accept',
        <String, String>{'roomId': rid, 'inviterId': '$inviterId'},
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) {
        return '加入房间失败：${(res['message'] ?? res['msg'] ?? 'code $code')}';
      }
      _roomId = rid;
      _inviterId = inviterId;
      _isCreator = false;
      _lastAppliedSeq = 0;
      // 官方示例：accept 成功后立即 check 校验房间
      await _api.post(
          '/listentogether/room/check', <String, String>{'roomId': rid},
          throwOnCode: false);
      return null;
    } catch (e) {
      return '加入房间失败：${_short(e)}';
    }
  }

  /// 离开/关闭房间。[end] = 房主关闭（listentogether/end）；否则仅本机停同步。
  Future<String?> leave({bool end = false}) async {
    final String? rid = _roomId;
    await stopSync();
    _roomId = null;
    _isCreator = false;
    _inviterId = 0;
    _lastAppliedSeq = 0;
    if (end && rid != null) {
      try {
        final Map<String, Object?> res = await _api.post(
          '/listentogether/end',
          <String, String>{'roomId': rid},
          throwOnCode: false,
        );
        final Map<String, Object?> data = apiPayload(res);
        final bool success =
            data['success'] == true || (res['code'] as num?)?.toInt() == 200;
        if (!success) return '房间关闭失败，可稍后重试';
      } catch (e) {
        return '房间关闭失败：${_short(e)}';
      }
    }
    return null;
  }

  /// 刷新房间状态（在线成员）。返回错误文案或 null。
  Future<String?> refreshStatus() async {
    final String? rid = _roomId;
    if (rid == null) return '当前不在房间内';
    try {
      final Map<String, Object?> res = await _api.post(
          '/listentogether/status', const <String, String>{},
          throwOnCode: false);
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      final Map<String, Object?> data = apiPayload(res);
      if (code != 200 || data['inRoom'] != true) {
        return '房间状态获取失败（可能已退出）';
      }
      final Map<String, Object?>? info =
          data['roomInfo'] as Map<String, Object?>?;
      final Object? users = info?['roomUsers'];
      if (users is List<Object?>) {
        onRoomChanged?.call(<ListenRoomUser>[
          for (final Object? u in users)
            if (u is Map<String, Object?>) ListenRoomUser.fromJson(u),
        ]);
      }
      return null;
    } catch (e) {
      return '房间状态获取失败：${_short(e)}';
    }
  }

  // ------------------------------------------------------------- 写通路

  /// 播放命令上报（GOTO/PLAY/PAUSE/PROGRESS）。返回错误文案或 null。
  Future<String?> sendPlayCommand(
    String commandType, {
    required int targetSongId,
    required int progressMs,
    required String playStatus,
  }) async {
    final String? rid = _roomId;
    if (rid == null) return '当前不在房间内';
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/play/command',
        <String, String>{
          'roomId': rid,
          'progress': '${progressMs.clamp(0, 1 << 31)}',
          'commandType': commandType,
          'formerSongId': '-1',
          'targetSongId': '$targetSongId',
          'clientSeq': '${_clientSeq++}',
          'playStatus': playStatus,
        },
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) {
        return '同步失败（${(res['message'] ?? 'code $code')}）';
      }
      return null;
    } catch (e) {
      return '同步失败：${_short(e)}';
    }
  }

  /// 队列公布（REPLACE 当前播放列表，加入者可取到整个列表）。返回错误文案或 null。
  Future<String?> syncList(List<int> songIds) async {
    final String? rid = _roomId;
    if (rid == null) return '当前不在房间内';
    final String csv = songIds.join(',');
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/sync/list/command',
        <String, String>{
          'roomId': rid,
          'commandType': 'REPLACE',
          'userId': '$_myUserId',
          'version': '${_clientSeq++}',
          'playMode': 'ORDER_LOOP',
          'displayList': csv,
          'randomList': csv,
        },
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) {
        return '队列同步失败（${(res['message'] ?? 'code $code')}）';
      }
      return null;
    } catch (e) {
      return '队列同步失败：${_short(e)}';
    }
  }

  /// 读取房间队列（sync/playlist/get → displayList.result，加入后同步本地列表）
  Future<List<int>> fetchRoomPlaylist() async {
    final String? rid = _roomId;
    if (rid == null) return const <int>[];
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/sync/playlist/get',
        <String, String>{'roomId': rid},
        throwOnCode: false,
      );
      final Map<String, Object?> data = apiPayload(res);
      final Object? playlist = data['playlist'];
      final Object? display =
          playlist is Map<String, Object?> ? playlist['displayList'] : null;
      final Object? result =
          display is Map<String, Object?> ? display['result'] : null;
      if (result is List<Object?>) {
        return <int>[
          for (final Object? v in result)
            if (v is num) v.toInt() else if (v is String) int.tryParse(v) ?? 0,
        ]..removeWhere((int v) => v <= 0);
      }
      return const <int>[];
    } catch (_) {
      return const <int>[];
    }
  }

  // ------------------------------------------------------------- 同步循环

  /// 启动轮询（2s 读对方命令）+ 心跳（10s 保活在场）。
  Future<void> startSync() async {
    if (_roomId == null) return;
    await stopSync();
    _polling = true;
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _heartbeat());
    unawaited(_poll());
  }

  Future<void> stopSync() async {
    _polling = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 轮询读通路：sync/playlist/get → playCommand（对方的命令）
  Future<void> _poll() async {
    if (!_polling || _roomId == null) return;
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/sync/playlist/get',
        <String, String>{'roomId': _roomId!},
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) return; // 抖动静默，下一轮再试
      final ListenPlayCommand? cmd = _extractCommand(apiPayload(res));
      if (cmd == null) return;
      if (cmd.serverSeq <= _lastAppliedSeq) return; // 旧命令幂等丢弃
      _lastAppliedSeq = cmd.serverSeq;
      if (cmd.userId == _myUserId) return; // 官方语义：读到的是对方的命令
      onCommand?.call(cmd);
    } catch (_) {
      // 静默：网络抖动下一轮重试
    }
  }

  /// 宽容解析 playCommand：兼容顶层 / playlist 包裹两种结构
  ListenPlayCommand? _extractCommand(Map<String, Object?> data) {
    Map<String, Object?>? raw =
        (data['playCommand'] ?? data['play_command']) as Map<String, Object?>?;
    if (raw == null) {
      final Object? playlist = data['playlist'];
      if (playlist is Map<String, Object?>) {
        raw = (playlist['playCommand'] ?? playlist['play_command'])
            as Map<String, Object?>?;
      }
    }
    if (raw == null) return null;
    final Object? seq = raw['serverSeq'] ?? raw['server_seq'];
    final Object? type = raw['commandType'] ?? raw['command_type'];
    if (seq == null || type == null) return null;
    final Object? song = raw['targetSongId'] ?? raw['songId'] ?? raw['songId'];
    return ListenPlayCommand(
      userId: (raw['userId'] as num?)?.toInt() ?? 0,
      commandType: '$type',
      targetSongId: (song as num?)?.toInt() ?? int.tryParse('$song') ?? 0,
      progressMs: (raw['progress'] as num?)?.toInt() ?? 0,
      playStatus: (raw['playStatus'] as String?) ?? '',
      serverSeq: (seq as num?)?.toInt() ?? 0,
      receivedAt: DateTime.now(),
    );
  }

  /// 心跳保活（携带本机当前播放状态）
  Future<void> _heartbeat() async {
    if (!_polling || _roomId == null) return;
    final ({int songId, bool playing, int progressMs})? st =
        statusSupplier?.call();
    try {
      await _api.post(
        '/listentogether/heartbeat',
        <String, String>{
          'roomId': _roomId!,
          'songId': '${st?.songId ?? 0}',
          'playStatus': (st?.playing ?? false) ? 'PLAY' : 'PAUSE',
          'progress': '${st?.progressMs ?? 0}',
        },
        throwOnCode: false,
      );
    } catch (_) {}
  }

  static String _short(Object e) {
    final String s = '$e';
    return s
        .replaceFirst(RegExp(r'^(ApiException|Exception)\(?'), '')
        .replaceAll(RegExp(r'\)?$'), '');
  }
}

/// 调试输出开关（release 静默）
void debugListenLog(String message) {
  if (kDebugMode) debugPrint('[listen-together] $message');
}
