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

  /// 最近一次读到的房间队列签名（空→非空/变化时回调 onRoomPlaylist）
  String _lastRoomPlaylistKey = '';

  /// 房间队列变化回调（轮询读到 displayList 变化时触发）。
  /// 上层（provider）据此把对方公布的队列采纳到本机 ——「切换歌单/
  /// 添加歌曲立即同步」的接收侧（第二十九批重补，二十八批丢失）。
  void Function(List<int> songIds)? onRoomPlaylist;

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
  ///
  /// ⚠️ 第二十九批「创建房间是概率事件」根治：清场（end）后服务端
  /// 会话残留偶发未过期，create 会把旧房间原样返回 → 旧版直接报错
  /// 「请等几秒后再创建」（用户视角=创建失败）。现在自动 **end 旧房
  /// → 等待 → 重试**（最多 3 次）；并用响应里的 creatorId 做**权威
  /// 复核**——返回他人房间（creatorId≠我，含 restart 后清场登记丢失
  /// 的场景）一律拒绝认领，绝不误置 isCreator=true。
  Future<String?> createRoom() async {
    // 本地持房检查放最前（无需登录/网络即可判定的硬防护）
    if (_roomId != null) {
      return '你已在一间一起听房间中，请先退出当前房间再创建';
    }
    final String? loginErr = await ensureLogin();
    if (loginErr != null) return loginErr;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        _ltLog('room/create 请求中(#$attempt)...');
        // 模块源码实证：refer 由 api-enhanced 模块内部硬编码
        //（songplay_more），客户端不传
        final Map<String, Object?> res = await _api
            .get('/listentogether/room/create', const <String, String>{});
        final Map<String, Object?> data = apiPayload(res);
        final Map<String, Object?>? roomInfo =
            (data['roomInfo'] ?? res['roomInfo']) as Map<String, Object?>?;
        final String? id = roomInfo?['roomId'] as String?;
        if (id == null || id.isEmpty) {
          _ltLog('room/create 响应缺房间号: ${res.keys.toList()}');
          return '创建房间失败：响应缺少房间号';
        }
        // 旧房间回显（清场残留）：end 掉再重试，用户无感
        if (_vacatedRoomIds.contains(id)) {
          _ltLog('room/create 返回旧房间 $id（清场残留），end 后重试');
          await endRoomById(id);
          if (attempt < 3) {
            await Future<void>.delayed(const Duration(milliseconds: 900));
            continue;
          }
          return '创建房间失败：旧房间仍在生效中，请几秒后再试';
        }
        // creatorId 权威复核：返回他人房间一律拒绝（「房主却是我」防线
        // 的最后一道，覆盖 restart 后清场登记丢失的场景）
        final int? creatorId =
            _toInt(roomInfo?['creatorId'] ?? roomInfo?['createUserId']);
        if (creatorId != null && creatorId > 0 && creatorId != _myUserId) {
          _ltLog('room/create 返回他人房间 creatorId=$creatorId '
              'me=$_myUserId，拒绝认领');
          return '创建房间失败：你的账号还在别人的房间中，请先退出再创建';
        }
        _ltLog('room/create 成功 roomId=$id');
        _roomId = id;
        _isCreator = true;
        _inviterId = _myUserId;
        _lastAppliedIdentity = '';
        _vacatedRoomIds.remove(id);
        return null;
      } catch (e) {
        _ltLog('room/create 失败(#$attempt): $e');
        if (attempt >= 3) return '创建房间失败：${_short(e)}';
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
    return '创建房间失败：请稍后再试';
  }

  /// 已清场/退出过的房间号登记（第二十九批，沿袭二十八批设计）：
  /// room/create 对在房账号会把旧房间原样返回 —— 响应若命中这里
  /// 登记的房间号，绝不误置 isCreator=true（「房主却是我」变体的防线）。
  final List<String> _vacatedRoomIds = <String>[];

  /// 登记「已清场/退出」的房间号（createRoom 旧房间回显防线）
  void markVacatedRoom(String roomId) {
    if (roomId.isEmpty) return;
    _vacatedRoomIds.add(roomId);
    if (_vacatedRoomIds.length > 5) {
      _vacatedRoomIds.removeAt(0);
    }
  }

  /// 对指定房间号调用 /listentogether/end（清场用：创建新房间前，
  /// 若服务端仍指认我在某房间且我是房主，先关掉旧房间）。
  Future<void> endRoomById(String roomId) async {
    if (roomId.isEmpty) return;
    bool ended = false;
    try {
      final Map<String, Object?> res = await _api.post(
          '/listentogether/end', <String, String>{'roomId': roomId},
          throwOnCode: false);
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      ended = code == 200;
      _ltLog('end($roomId) => code=${res['code']} '
          'success=${apiPayload(res)['success']} ended=$ended');
    } catch (e) {
      _ltLog('end($roomId) 失败: $e');
    }
    if (ended) {
      // 已确认关闭：解除旧房登记 —— 网易可能复用房间号，登记会误拦
      // 后续创建返回的同一房间号（「清场后永远创建不了」变体）
      _vacatedRoomIds.remove(roomId);
    } else {
      markVacatedRoom(roomId);
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
    if (rid != null) markVacatedRoom(rid);
    _ltLog('leave(end=$end) rid=$rid');
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
        _ltLog('play/command($commandType song=$targetSongId) 失败 '
            'code=$code msg=${res['message'] ?? res['msg']}');
        return '同步失败（${(res['message'] ?? res['msg'] ?? 'code $code')}）';
      }
      _ltLog('play/command $commandType song=$targetSongId '
          'progress=${progressMs.clamp(0, 1 << 31)} status=$playStatus ok');
      return null;
    } catch (e) {
      _ltLog('play/command($commandType) 异常: $e');
      return '同步失败：${_short(e)}';
    }
  }

  /// 队列公布（REPLACE 当前播放列表，加入者可取到整个列表）。返回错误文案或 null。
  ///
  /// ⚠️ 参数形态（第二十九批线上实证）：api-enhanced 模块源码是**服务端**
  /// 把平铺字段包装成 playlistParam JSON 串 —— 客户端必须发送**平铺参数**
  /// （commandType/userId/version/randomList CSV/displayList CSV）。二十八批
  /// 误改为客户端自带 playlistParam JSON —— 模块读不到 query.randomList →
  /// `undefined.split()` 抛错 → 线上实测 `code=404 msg=null`（队列从未公布
  /// 成功，成员 playlist/get 恒空 →「完全各听各的」的直接根因）。本版回归
  /// 平铺参数并补诊断日志。
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
        _ltLog('sync/list(REPLACE n=${songIds.length}) 失败 '
            'code=$code msg=${res['message'] ?? res['msg']}');
        return '队列同步失败（${(res['message'] ?? res['msg'] ?? 'code $code')}）';
      }
      _ltLog('sync/list REPLACE n=${songIds.length} ok');
      return null;
    } catch (e) {
      _ltLog('sync/list 异常: $e');
      return '队列同步失败：${_short(e)}';
    }
  }

  /// 读取房间队列（sync/playlist/get → displayList，加入后同步本地列表）。
  ///
  /// 第二十九批字段宽容升级（沿袭二十八批）：响应结构在不同部署/版本间
  /// 差异大，改为深度递归搜索 displayList（任意层级、数组/CSV字符串/
  /// 对象元素均兼容），并同步登记队列签名（避免轮询重复回调）。
  Future<List<int>> fetchRoomPlaylist() async {
    final String? rid = _roomId;
    if (rid == null) return const <int>[];
    try {
      final Map<String, Object?> res = await _api.post(
        '/listentogether/sync/playlist/get',
        <String, String>{'roomId': rid},
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code != 200) {
        _ltLog('playlist/get 失败 code=$code');
        return const <int>[];
      }
      final Map<String, Object?> data = apiPayload(res);
      final List<int> ids = extractSongIds(data);
      if (ids.isNotEmpty) {
        _lastRoomPlaylistKey = ids.join(',');
        _ltLog('playlist/get => ${ids.length} 首');
        return ids;
      }
      _ltLog('playlist/get 无队列字段 keys=${data.keys.toList()}');
      return const <int>[];
    } catch (e) {
      _ltLog('playlist/get 异常: $e');
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

  /// 轮询读通路：sync/playlist/get → 房间队列变化 + playCommand（房内最新命令）
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
        _ltLog('poll => 488 房间失效');
        onRoomExpired?.call();
        return;
      }
      if (code != 200) {
        // 抖动静默，下一轮再试（偶发 code 记录一下便于诊断）
        if (code != 0) _ltLog('poll => code=$code（静默重试）');
        return;
      }
      final Map<String, Object?> payload = apiPayload(res);
      // 房间队列变化（对方 REPLACE 公布）→ 通知上层采纳
      //（「切换歌单/添加歌曲立即同步」的接收侧，第二十九批重补）
      final List<int> roomIds = extractSongIds(payload);
      if (roomIds.isNotEmpty) {
        final String key = roomIds.join(',');
        if (key != _lastRoomPlaylistKey) {
          _lastRoomPlaylistKey = key;
          _ltLog('poll 房间队列变化 => ${roomIds.length} 首');
          onRoomPlaylist?.call(roomIds);
        }
      }
      final ListenPlayCommand? cmd = extractPlayCommand(payload);
      if (cmd == null) {
        _lastEmptyPoll = true;
        return;
      }
      if (_lastEmptyPoll) {
        _lastEmptyPoll = false;
        _ltLog('poll 收到首条命令: type=${cmd.commandType} '
            'song=${cmd.targetSongId} from=${cmd.userId} me=$_myUserId');
      }
      // 幂等判重：同一命令元组重复读到时丢弃（serverSeq 随读取变化，
      // 不能用作新旧判定 —— 实测同一命令两次读 serverSeq 不同）
      if (cmd.identity == _lastAppliedIdentity) return;
      _lastAppliedIdentity = cmd.identity;
      if (cmd.userId == _myUserId) {
        // 官方语义：读到带自己 userId 的命令通常是本机命令回显；
        // 例外：clientSeq==0 的初始命令是 accept 后服务端为
        // 新成员合成的「加入对齐」（指向房间当前歌），要应用。
        if (!(cmd.clientSeq == 0 && cmd.targetSongId > 0)) {
          _ltLog('poll 跳过本机回显: type=${cmd.commandType} '
              'song=${cmd.targetSongId} seq=${cmd.clientSeq}');
          return;
        }
        _ltLog('poll 应用加入对齐命令: song=${cmd.targetSongId}');
      } else {
        _ltLog('poll 应用对方命令: type=${cmd.commandType} '
            'song=${cmd.targetSongId} progress=${cmd.progressMs} '
            'status=${cmd.playStatus} from=${cmd.userId}');
      }
      onCommand?.call(cmd);
    } catch (e) {
      _ltLog('poll 异常: $e');
    }
  }

  /// 上一次轮询是否为空（只在 空→非空 边界打日志，避免每 2s 刷屏）
  bool _lastEmptyPoll = true;

  /// 宽容解析 playCommand（第二十九批升级，公开静态供单测）：深度递归
  /// 找任意带 commandType 的 map —— 顶层 playCommand / playList 内嵌 /
  /// commandHead+commandInfo 分层结构均兼容。字段合并顺序：命中层 →
  /// 命中层自带的 commandInfo/commandHead 子层 → 命中层为 commandInfo
  /// 时的**兄弟层** commandHead（网易真实结构 playCommand{commandHead:
  /// {userId,serverSeq}, commandInfo:{commandType,...}}）与父层兑底字段。
  /// 优先取「播放型」命令，全无时回退第一条（REPLACE 等队列型命令无害：
  /// 上层按 targetSongId=0 忽略）。
  static ListenPlayCommand? extractPlayCommand(Map<String, Object?> data) {
    ({
      Map<String, Object?> map,
      Map<String, Object?>? parent,
      Object? key
    })? hit = _findCommandMap(data, true);
    hit ??= _findCommandMap(data, false);
    if (hit == null) return null;
    final Map<String, Object?> merged = Map<String, Object?>.of(hit.map);
    for (final String k in const <String>[
      'commandInfo',
      'command_info',
      'commandHead',
      'command_head',
    ]) {
      final Object? layer = hit.map[k];
      if (layer is Map<String, Object?>) merged.addAll(layer);
    }
    final String hitKey = '${hit.key}';
    if (hitKey == 'commandInfo' || hitKey == 'command_info') {
      // 兄弟层 commandHead 携带 userId/serverSeq（不在 commandInfo 内）
      for (final String k in const <String>['commandHead', 'command_head']) {
        final Object? layer = hit.parent?[k];
        if (layer is Map<String, Object?>) merged.addAll(layer);
      }
      // 父层兑底：仅填补缺失键（不覆盖命中层已提取的值）
      hit.parent?.forEach((Object? k, Object? v) {
        if (k is String && merged[k] == null) merged[k] = v;
      });
    }
    final Object? type = merged['commandType'] ?? merged['command_type'];
    if (type == null) return null;
    final Object? seq = merged['serverSeq'] ?? merged['server_seq'];
    final Object? song =
        merged['targetSongId'] ?? merged['target_song_id'] ?? merged['songId'];
    return ListenPlayCommand(
      userId: _toInt(merged['userId']) ?? 0,
      commandType: '$type',
      targetSongId: _toInt(song) ?? 0,
      progressMs: _toInt(merged['progress']) ?? 0,
      playStatus: '${merged['playStatus'] ?? merged['play_status'] ?? ''}',
      serverSeq: _toInt(seq) ?? 0,
      clientSeq: _toInt(merged['clientSeq'] ?? merged['client_seq']) ?? 0,
      receivedAt: DateTime.now(),
    );
  }

  /// 深度递归找带 commandType 的 map（记录父 map 与在父层中的键名，
  /// 供 commandInfo 兄弟层 commandHead 合并）。playOnly=true 时跳过
  /// REPLACE/ADD 队列型命令。
  static ({
    Map<String, Object?> map,
    Map<String, Object?>? parent,
    Object? key
  })? _findCommandMap(
    Object? node,
    bool playOnly, {
    Map<String, Object?>? parent,
    Object? key,
  }) {
    if (node is Map<String, Object?>) {
      final Object? t = node['commandType'] ?? node['command_type'];
      if (t != null) {
        final String ts = '$t';
        if (!playOnly || (ts != 'REPLACE' && ts != 'ADD')) {
          return (map: node, parent: parent, key: key);
        }
      }
      for (final MapEntry<String, Object?> e in node.entries) {
        final ({
          Map<String, Object?> map,
          Map<String, Object?>? parent,
          Object? key
        })? r = _findCommandMap(e.value, playOnly, parent: node, key: e.key);
        if (r != null) return r;
      }
    } else if (node is List<Object?>) {
      for (final Object? child in node) {
        final ({
          Map<String, Object?> map,
          Map<String, Object?>? parent,
          Object? key
        })? r = _findCommandMap(child, playOnly, parent: parent, key: key);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// 深度优先在任意嵌套结构中找 key 对应的值（响应结构在不同部署/
  /// 版本间差异大：playList/playlist、任意包裹层均兼容）。
  static Object? _findDeep(Object? node, String key) {
    if (node is Map<String, Object?>) {
      final Object? v = node[key];
      if (v != null) return v;
      for (final Object? child in node.values) {
        final Object? r = _findDeep(child, key);
        if (r != null) return r;
      }
    } else if (node is List<Object?>) {
      for (final Object? child in node) {
        final Object? r = _findDeep(child, key);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// 从任意响应负载中提取房间队列 id 列表（深度搜索 displayList，
  /// 回退 randomList；元素兼容 num/字符串 CSV/对象 {id, songId} 三形态）
  static List<int> extractSongIds(Object? payload) {
    final Object? raw =
        _findDeep(payload, 'displayList') ?? _findDeep(payload, 'randomList');
    final List<Object?>? items = raw is List<Object?>
        ? raw
        : raw is String && raw.isNotEmpty
            ? raw.split(',')
            : null;
    if (items == null) return const <int>[];
    return <int>[
      for (final Object? v in items)
        if (v is num)
          v.toInt()
        else if (v is String)
          int.tryParse(v.trim()) ?? 0
        else if (v is Map<String, Object?>)
          (v['id'] as num?)?.toInt() ??
              (v['songId'] as num?)?.toInt() ??
              int.tryParse('${v['id'] ?? v['songId']}') ??
              0,
    ]..removeWhere((int v) => v <= 0);
  }

  /// 数字宽容转换（num/字符串均可；解析失败返回 null）
  static int? _toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
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

/// 一起听诊断日志（`[listen]` 前缀 + 时间戳，release 也可输出 ——
/// 用户可直接导出 logcat 取证同步链路；二十九批重补，二十八批丢失）
void _ltLog(String message) {
  final String ts = DateTime.now().toString();
  debugPrint(
      '[listen] ${ts.length >= 23 ? ts.substring(11, 23) : ts} $message');
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
