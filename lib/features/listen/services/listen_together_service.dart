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
///  - `POST /listentogether/heatbeat`           保活 {roomId, songId, playStatus, progress}；
///  - `POST /listentogether/status`             房间状态 + roomUsers[]；
///  - `POST /listentogether/end`                关闭房间。
///
/// 同步策略（第二十六批按官方 demo + 线上实测修正）：
///  - 双端对称：房间内任何成员的换歌/播放暂停/拖动都会经 play/command
///    上报，其余成员轮询 sync/playlist/get 读取并应用；
///  - 幂等判重不能用 serverSeq：实测它随每次读取变化（服务端时间戳），
///    同一命令两次读到不同的 serverSeq，会导致 seek 命令被反复应用；
///    改用完整命令元组（userId+commandType+targetSongId+progress+
///    playStatus+clientSeq）判重；
///  - 加入对齐：accept 成功后服务端会为新成员合成一条初始命令
///    （userId=自己、clientSeq=0、targetSongId=房间当前歌），作为
///    「加入对齐」应用，加入者秒级对齐无需等房主广播；
///  - 命令类型分派：GOTO 无条件换歌；PLAY/PAUSE 只动播放状态；
///    PROGRESS/seek 只动进度 —— 播放暂停不靠位置差推断（官方 demo 的
///    'seek' 归一化为 PROGRESS 处理）；
///  - 进度是快照：应用时按「收到时刻」补流逝时间（仅播放中）；
///  - 防回环：应用对方命令后的短暂窗口内不上报本机推断的状态变化；
///  - 心跳保活：网易原始拼写是 heatbeat（heartbeat 是不存在的路由！），
///    服务端实测返回 timeSpan:30 提示建议间隔；房间在无心跳下会很快
///    失效（实测已失效时 accept 返回 HTTP 488「一起听已失效」——即
///    「无法加入一起听 HTTP 488」的根因），双端都必须按心跳保活。
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

/// 服务端视角的房间快照（probeServerRoom 返回，会话自愈用）
class ListenServerRoom {
  const ListenServerRoom({
    required this.roomId,
    required this.users,
    required this.hostId,
    required this.myUserId,
  });

  final String roomId;
  final List<ListenRoomUser> users;

  /// 房主 userId（服务端未提供房主字段时为 null —— 上层缺省按访客恢复）
  final int? hostId;
  final int myUserId;

  /// 服务端明确指认我是房主（hostId 缺失时不猜）
  bool get iAmHost => hostId != null && hostId == myUserId;
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
    this.clientSeq = 0,
  });

  final int userId;
  final String commandType;
  final int targetSongId;

  /// 命令发出时刻的播放进度快照（毫秒）
  final int progressMs;
  final String playStatus;
  final int serverSeq;

  /// 发送方客户端序号（第二十六批：判重元组组成部分；
  /// 0 = 服务端为加入方合成的初始对齐命令）
  final int clientSeq;

  /// 本机收到时刻（进度补流逝用）
  final DateTime receivedAt;

  /// 归一化类型：官方 demo 的 'seek' 与 YunYin 的 'PROGRESS' 同义
  bool get isSeek =>
      commandType == 'PROGRESS' || commandType.toLowerCase() == 'seek';
  bool get isGoto => commandType == 'GOTO';
  bool get isPlay => commandType == 'PLAY';
  bool get isPause => commandType == 'PAUSE';

  /// 幂等判重键（第二十六批：serverSeq 随读取变化不可用作判重，
  /// 改用完整命令元组 —— 同一命令重复轮询读到时元组不变，不重复应用）
  String get identity =>
      '$userId|$commandType|$targetSongId|$progressMs|$playStatus|$clientSeq';
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

  /// 已应用命令的元组标识（第二十六批：替代不可靠的 serverSeq 判重）
  String _lastAppliedIdentity = '';

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

  /// 是否已有缓存的登录身份（轻量检查，不发起网络请求；
  /// 未确认过登录态时自愈探测跳过，避免未登录状态下空转请求）
  bool get ensureLoginQuickCheck => _myUserId > 0;

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

  /// 角色被服务端权威校正（第二十七批：status 返回的房主字段与本地
  /// isCreator 冲突时触发，参数 = 服务端指认我是否为房主）
  void Function(bool iAmHost)? onRoleCorrected;

  /// 房间已失效（第二十六批：accept/心跳/状态返回 488 或 inRoom=false，
  /// 房间会话已死亡 —— 通知房主重建、告知访客重新邀请）
  void Function()? onRoomExpired;

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

  /// 创建房间。返回错误文案或 null。
  ///
  /// ⚠️ 第二十七批「房主却是我」恶性 Bug 根治：网易原始接口
  /// `/api/listen/together/room/create` 的官方语义是「账号已在房间时
  /// 返回已存在的房间」——访客加入好友房间后（或杀进程重开、本地
  /// 状态已丢而服务端会话仍在时）再调 create，服务端会把**当前所在的
  /// 好友房间**原样返回，本地就会把自己误置为房主（isCreator=true），
  /// 还会把访客的队列 REPLACE 覆盖房主队列（房间被访客篡改）。
  /// 因此本端硬性防护：service 已持房时拒绝重复创建；上层 Notifier
  /// 另有「创建前 status 前置检查 + 服务端房间恢复」双保险。
  Future<String?> createRoom() async {
    // 本地持房检查放最前（无需登录/网络即可判定的硬防护）
    if (_roomId != null) {
      return '你已在一间一起听房间中，请先退出当前房间再创建';
    }
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
      _lastAppliedIdentity = '';
      return null;
    } catch (e) {
      return '创建房间失败：${_short(e)}';
    }
  }

  // ----------------------------------------------------- 服务端会话自愈

  /// 探测服务端视角的房间（status + room/check 权威取证）。
  ///
  /// 场景：杀进程重开 / 状态清理不彻底时，本地 `_roomId == null` 但
  /// 网易服务端会话仍在好友房间里。此时任何 create 都会被服务端以
  /// 「返回当前所在房间」应答，进而误置房主 —— 所以在创建前与页面
  /// 打开时都要先探测一次。
  ///
  /// 返回 null = 服务端确认不在房间（可安全创建）；
  /// 返回记录 = 服务端仍在房间（上层应以恢复姿态处理，禁止创建）。
  Future<ListenServerRoom?> probeServerRoom() async {
    try {
      final Map<String, Object?> res = await _api.post(
          '/listentogether/status', const <String, String>{},
          throwOnCode: false);
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) return null;
      final Map<String, Object?> data = apiPayload(res);
      if (data['inRoom'] != true) return null;
      final Map<String, Object?>? info =
          data['roomInfo'] as Map<String, Object?>?;
      final String? rid = info?['roomId'] as String?;
      if (rid == null || rid.isEmpty) return null;
      final List<ListenRoomUser> users = <ListenRoomUser>[
        for (final Object? u
            in (info?['roomUsers'] as List<Object?>? ?? const <Object?>[]))
          if (u is Map<String, Object?>) ListenRoomUser.fromJson(u),
      ];
      // 权威角色判定：roomInfo / room/check 返回里宽容找房主标识；
      // 找不到时以 null 返回（上层缺省按访客恢复，绝不默认房主）。
      int? hostId = _extractHostId(info);
      if (hostId == null) {
        try {
          final Map<String, Object?> res2 = await _api.post(
              '/listentogether/room/check', <String, String>{'roomId': rid},
              throwOnCode: false);
          final Map<String, Object?> data2 = apiPayload(res2);
          hostId = _extractHostId(
              (data2['roomInfo'] ?? data2) as Map<String, Object?>?);
        } catch (_) {}
      }
      if (hostId == null) {
        debugListenLog('probeServerRoom: 服务端在房 roomId=$rid '
            'roomUsers=${users.length} 未找到房主字段，按访客恢复');
      } else {
        debugListenLog('probeServerRoom: 服务端在房 roomId=$rid hostId=$hostId '
            'me=$_myUserId => 房主=${hostId == _myUserId}');
      }
      return ListenServerRoom(
          roomId: rid, users: users, hostId: hostId, myUserId: _myUserId);
    } catch (e) {
      debugListenLog('probeServerRoom 失败: $e');
      return null;
    }
  }

  /// 宽容提取房主 userId（顶层函数 [extractListenHostId] 的转发，
  /// 便于全模块复用与单测）
  static int? _extractHostId(Map<String, Object?>? info) =>
      extractListenHostId(info);

  /// 以恢复姿态回填本地房间状态（服务端会话自愈用，不触发任何写通路）。
  void resumeRoom(
      {required String roomId,
      required int inviterId,
      required bool isCreator}) {
    _roomId = roomId;
    _inviterId = inviterId;
    _isCreator = isCreator;
    _lastAppliedIdentity = '';
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
        // 第二十六批：488 = 一起听已失效（房间会话已死亡），给出可行动文案
        if (code == 488) {
          return '一起听房间已失效，请让好友重新发起邀请后再加入';
        }
        return '加入房间失败：${(res['message'] ?? res['msg'] ?? 'code $code')}';
      }
      _roomId = rid;
      _inviterId = inviterId;
      _isCreator = false;
      _lastAppliedIdentity = '';
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
    _lastAppliedIdentity = '';
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
      if (code == 488 || (code == 200 && data['inRoom'] != true)) {
        // 房间会话已死亡（第二十六批：以 488 与 inRoom!=true 为准触发
        // 失效回调，网络抖动的其他错误码不误杀本地房间状态）
        onRoomExpired?.call();
        return '一起听房间已失效';
      }
      if (code != 200) {
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
      // 角色权威校正（第二十七批「房主却是我」防御纵深）：status 每次
      // 刷新都宽容找房主字段，服务端指认与本地 isCreator 冲突时以服务端
      // 为准 —— 本地状态无论怎么漂移（误置 host/guest）都能自动拉回。
      // 找不到房主字段时不猜，保持本地判定。
      final int? hostId = _extractHostId(info);
      if (hostId != null && hostId > 0) {
        final bool serverSaysHost = hostId == _myUserId;
        if (serverSaysHost != _isCreator) {
          debugListenLog('refreshStatus 角色校正: 服务端 hostId=$hostId '
              'me=$_myUserId 本地isCreator=$_isCreator => $serverSaysHost');
          _isCreator = serverSaysHost;
          onRoleCorrected?.call(serverSaysHost);
        }
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

  /// 轮询读通路：sync/playlist/get → playCommand（房内最新命令）
  Future<void> _poll() async {
    if (!_polling || _roomId == null) return;
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/sync/playlist/get',
        <String, String>{'roomId': _roomId!},
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code == 488) {
        // 房间会话已死亡：停止轮询并通知上层重建/退出
        onRoomExpired?.call();
        return;
      }
      if (code != 200) return; // 抖动静默，下一轮再试
      final ListenPlayCommand? cmd = _extractCommand(apiPayload(res));
      if (cmd == null) return;
      // 幂等判重：同一命令元组重复读到时丢弃（serverSeq 随读取变化，
      // 不能用作新旧判定 —— 实测同一命令两次读 serverSeq 不同）
      if (cmd.identity == _lastAppliedIdentity) return;
      _lastAppliedIdentity = cmd.identity;
      if (cmd.userId == _myUserId) {
        // 官方语义：读到带自己 userId 的命令通常是本机命令回显；
        // 例外：clientSeq==0 的初始命令是 accept 后服务端为
        // 新成员合成的「加入对齐」（指向房间当前歌），要应用。
        if (!(cmd.clientSeq == 0 && cmd.targetSongId > 0)) return;
      }
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
      clientSeq: (raw['clientSeq'] as num?)?.toInt() ?? 0,
      receivedAt: DateTime.now(),
    );
  }

  /// 心跳保活（携带本机当前播放状态）。
  /// 路由是网易原始拼写 heatbeat（heartbeat 路由不存在 —— 第二十六批
  /// 实测：打错路由导致房间无人保活很快失效，好友加入时 accept 返向
  /// HTTP 488「一起听已失效」。
  Future<void> _heartbeat() async {
    if (!_polling || _roomId == null) return;
    final ({int songId, bool playing, int progressMs})? st =
        statusSupplier?.call();
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/heatbeat',
        <String, String>{
          'roomId': _roomId!,
          'songId': '${st?.songId ?? 0}',
          'playStatus': (st?.playing ?? false) ? 'PLAY' : 'PAUSE',
          'progress': '${st?.progressMs ?? 0}',
        },
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code == 488) {
        // 房间已失效：停止保活并通知上层
        onRoomExpired?.call();
      }
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

/// 宽容提取房主 userId：不同部署/版本字段名不定，逐个候选键匹配。
/// （只认明确命中，找不到返回 null —— 宁可按访客恢复也不误判房主。）
///
/// 候选形态（线上/官方客户端常见）：
///  - roomInfo 顶层整型：hostUserId / hostId / creatorId / createUserId /
///    ownerId / roomOwnerId / anchorUserId；
///  - roomUsers[] 项：isHost / isCreator 布尔（true/1/'1'），
///    或 userType / userRole / role / userIdentity / memberType == 1
///    （网易常见约定 1=房主）。
int? extractListenHostId(Map<String, Object?>? info) {
  if (info == null) return null;
  const List<String> intKeys = <String>[
    'hostUserId',
    'hostId',
    'creatorId',
    'createUserId',
    'ownerId',
    'roomOwnerId',
    'anchorUserId',
  ];
  for (final String k in intKeys) {
    final Object? v = info[k];
    final int? id = v is num
        ? v.toInt()
        : v is String
            ? int.tryParse(v)
            : null;
    if (id != null && id > 0) return id;
  }
  final Object? users = info['roomUsers'];
  if (users is List<Object?>) {
    for (final Object? u in users) {
      if (u is! Map<String, Object?>) continue;
      for (final String k in const <String>['isHost', 'isCreator']) {
        if (u[k] == true || u[k] == 1 || u[k] == '1') {
          final Object? uid = u['userId'];
          final int? id = uid is num
              ? uid.toInt()
              : uid is String
                  ? int.tryParse(uid)
                  : null;
          if (id != null && id > 0) return id;
        }
      }
      const List<String> roleKeys = <String>[
        'userType',
        'userRole',
        'role',
        'userIdentity',
        'memberType',
      ];
      for (final String k in roleKeys) {
        final Object? v = u[k];
        // 常见约定：1=房主（TYPE_HOST），0/2=普通成员
        final int? role = v is num
            ? v.toInt()
            : v is String
                ? int.tryParse(v)
                : null;
        if (role == 1) {
          final Object? uid = u['userId'];
          final int? id = uid is num
              ? uid.toInt()
              : uid is String
                  ? int.tryParse(uid)
                  : null;
          if (id != null && id > 0) return id;
        }
      }
    }
  }
  return null;
}
