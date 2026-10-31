/// 一起听全局状态机（第二十五批需求：播放页一起听样式与逻辑闭环）。
///
/// 历史缺口：第十三批的一起听逻辑全部绑在 [ListenTogetherPage] 的
/// State 里 —— 离开页面即解绑 onCommand/onRoomChanged，对方切歌本端
/// 不再跟随（轮询虽在跑，命令却被丢弃）；播放页也没有任何入口。
///
/// 本文件把「命令应用 / 状态上报 / 成员刷新 / 邀请串构造与解析」全部
/// 提升为应用级 Notifier（keepAlive）：
///  - 无论停在哪个页面，房内命令都持续应用（真·闭环）；
///  - 成员变化自动广播当前歌（新加入者 ≤10s 拿到房主正在播放的歌）；
///  - 播放页 / 一起听页 / 好友页共享同一份房间状态，无双份逻辑。
library;

import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart' show Song;
import '../../../core/utils/platform_actions.dart';
import '../../../core/widgets/app_notify.dart';
import '../../discover/data/netease_providers.dart'
    show neteaseApiProvider, neteaseRepositoryProvider;
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../services/listen_together_service.dart';

/// 全局唯一一起听服务实例（复用网易云 API 客户端与登录 cookie）。
/// 从页面文件迁移至此，供 Notifier 与各页面共用。
final Provider<ListenTogetherService> listenServiceProvider =
    Provider<ListenTogetherService>(
        (Ref ref) => ListenTogetherService(ref.read(neteaseApiProvider)));

// ---------------------------------------------------------------- 邀请串

/// 一对邀请凭据（官方 accept 需要 房间号 + 邀请人ID 成对）。
class ListenInvite {
  const ListenInvite({required this.roomId, required this.inviterId});

  final String roomId;
  final int inviterId;

  @override
  bool operator ==(Object other) =>
      other is ListenInvite &&
      other.roomId == roomId &&
      other.inviterId == inviterId;

  @override
  int get hashCode => Object.hash(roomId, inviterId);
}

/// 深链模板：好友点击直接拉起 App 加入（Android intent-filter 注册）。
String buildListenInviteLink(String roomId, int inviterId) =>
    'mingmusic://listen/join?roomId=$roomId&inviterId=$inviterId';

/// 系统分享全文：深链 + 邀请串兜底（微信等场景点不了自定义 scheme，
/// 复制邀请串到 App 内粘贴同样能加入 —— 双路保证「好友可点击加入」）。
String buildListenShareText(String roomId, int inviterId) =>
    '【MingMusic 一起听】点击链接加入房间，和我同步听歌：\n'
    '${buildListenInviteLink(roomId, inviterId)}\n\n'
    '若链接无法点击：复制下面这串邀请码，打开 MingMusic → 我的 → 一起听 → '
    '「加入一起听」粘贴即可：\n'
    '$roomId|$inviterId';

/// 宽容解析邀请信息（分享文本 / 剪贴板 / 深链 URL 原文通吃）：
///  ① 深链：mingmusic://listen/join?roomId=X&inviterId=Y（容忍引号与空白）；
///  ② 邀请串：房间号|邀请人ID（允许夹在任意文本中，如聊天记录整段复制）。
ListenInvite? parseListenInvite(String raw) {
  final String s = raw.trim();
  if (s.isEmpty) return null;
  final RegExpMatch? room =
      RegExp(r'roomId\s*=\s*([^&\s<>]+)', caseSensitive: false).firstMatch(s);
  final RegExpMatch? inviter =
      RegExp(r'inviterId\s*=\s*([^&\s<>]+)', caseSensitive: false)
          .firstMatch(s);
  if (room != null && inviter != null) {
    final int inv = int.tryParse(inviter.group(1)!.trim()) ?? 0;
    final String rid = room.group(1)!.trim();
    if (rid.isNotEmpty && inv > 0) {
      return ListenInvite(roomId: rid, inviterId: inv);
    }
  }
  // 邀请串：房间号|邀请人ID（允许夹在任意文本中，如聊天记录整段复制）。
  // 第二十六批实测：真实 roomId 是 <hex32>_<时间戳> 形态
  // （如 057eb172ecb5eff6b23464510a241f79_1793444501），旧正则
  // (\d{4,})|(只匹配纯数字)会把竖线前的数字尾巴当时房间号，
  // 丢掉 hex 前缀导致加入必失败 —— 现在优先匹配 hex(+_时间戳)整体。
  final RegExpMatch? pair = RegExp(
    r'([0-9a-fA-F]{4,}(?:_[0-9]{6,})?|\d{4,})\s*[|｜]\s*(\d{2,})',
  ).firstMatch(s);
  if (pair != null) {
    final int inv = int.tryParse(pair.group(2)!) ?? 0;
    if (inv > 0) {
      return ListenInvite(roomId: pair.group(1)!, inviterId: inv);
    }
  }
  return null;
}

// ---------------------------------------------------------------- 状态

/// 房间阶段（驱动各处 UI 呈现）
enum ListenRoomPhase {
  /// 未在房间
  idle,

  /// 创建/加入请求进行中
  busy,

  /// 房主（创建者）
  host,

  /// 客人（被邀请方）
  guest,
}

class ListenRoomState {
  const ListenRoomState({
    this.phase = ListenRoomPhase.idle,
    this.roomId = '',
    this.inviterId = 0,
    this.users = const <ListenRoomUser>[],
    this.remoteSongId = 0,
    this.notice = '',
    this.roomSongIds = const <int>[],
    this.loggedIn = false,
    this.nickname = '',
  });

  final ListenRoomPhase phase;
  final String roomId;
  final int inviterId;

  /// 在线成员（/listentogether/status → roomInfo.roomUsers）
  final List<ListenRoomUser> users;

  /// 对方最近命令指向的歌（房间同步指示）
  final int remoteSongId;

  /// 非致命提示（分享给 UI 展示）
  final String notice;

  /// 房间公布的播放列表（sync/playlist/get → displayList）
  final List<int> roomSongIds;

  final bool loggedIn;
  final String nickname;

  bool get inRoom =>
      phase == ListenRoomPhase.host || phase == ListenRoomPhase.guest;
  bool get busy => phase == ListenRoomPhase.busy;

  ListenRoomState copyWith({
    ListenRoomPhase? phase,
    String? roomId,
    int? inviterId,
    List<ListenRoomUser>? users,
    int? remoteSongId,
    String? notice,
    List<int>? roomSongIds,
    bool? loggedIn,
    String? nickname,
  }) {
    return ListenRoomState(
      phase: phase ?? this.phase,
      roomId: roomId ?? this.roomId,
      inviterId: inviterId ?? this.inviterId,
      users: users ?? this.users,
      remoteSongId: remoteSongId ?? this.remoteSongId,
      notice: notice ?? this.notice,
      roomSongIds: roomSongIds ?? this.roomSongIds,
      loggedIn: loggedIn ?? this.loggedIn,
      nickname: nickname ?? this.nickname,
    );
  }
}

// ---------------------------------------------------------------- Notifier

class ListenRoomNotifier extends Notifier<ListenRoomState> {
  ListenTogetherService get _svc => ref.read(listenServiceProvider);

  Timer? _memberTimer;

  /// 跟随换歌进行中（抑制本机状态上报，避免把对方命令反向报回）
  bool _following = false;

  /// 上次上报的歌曲/播放状态（变化才上报，减少无效请求）
  int? _lastReportedSongId;
  bool? _lastReportedPlaying;

  @override
  ListenRoomState build() {
    // 回调注册一次（Notifier keepAlive，生命周期=进程）
    _svc.onCommand = _applyCommand;
    _svc.onRoomChanged = _onRoomChanged;
    _svc.onRoomExpired = _onRoomExpired;
    _svc.onRoleCorrected = _onRoleCorrected;
    _svc.statusSupplier = () {
      final PlayerState ps = ref.read(playerProvider);
      return (
        songId: ps.currentTrack?.neteaseId ?? 0,
        playing: ps.playing,
        progressMs:
            ref.read(audioHandlerProvider).player.position.inMilliseconds,
      );
    };
    // 本机播放状态变化 → 上报命令（全局生效：任何页面都闭环）
    ref.listen<PlayerState>(playerProvider, (_, PlayerState ps) {
      _reportLocalState(ps);
    });
    ref.onDispose(() {
      _memberTimer?.cancel();
      _memberTimer = null;
    });
    // 进程内恢复：service 已在房间（页面切换不销毁 Notifier，一般不触发；
    // 兜底处理热恢复）
    if (_svc.inRoom) {
      _svc.startSync();
      _startMemberLoop();
      unawaited(_ensureLogin().then<void>((_) => refreshStatus(silent: true)));
      return ListenRoomState(
        phase: _svc.isCreator ? ListenRoomPhase.host : ListenRoomPhase.guest,
        roomId: _svc.roomId ?? '',
        inviterId: _svc.inviterId,
      );
    }
    return const ListenRoomState();
  }

  // ----------------------------------------------------------- 登录

  Future<bool> _ensureLogin() async {
    final String? err = await _svc.ensureLogin();
    state = state.copyWith(loggedIn: err == null, nickname: _svc.nickname);
    return err == null;
  }

  // ----------------------------------------------------------- 本机上报

  /// 播放状态变化上报（换歌 → GOTO；播放暂停 → PLAY/PAUSE；变化才发）
  void _reportLocalState(PlayerState ps) {
    if (_following || !state.inRoom || _svc.reportSuppressed) return;
    final int songId = ps.currentTrack?.neteaseId ?? 0;
    if (songId <= 0) return;
    final int progressMs =
        ref.read(audioHandlerProvider).player.position.inMilliseconds;
    if (songId != _lastReportedSongId) {
      _lastReportedSongId = songId;
      _lastReportedPlaying = ps.playing;
      unawaited(_svc.sendPlayCommand(
        'GOTO',
        targetSongId: songId,
        progressMs: progressMs,
        playStatus: ps.playing ? 'PLAY' : 'PAUSE',
      ));
    } else if (_lastReportedPlaying != ps.playing) {
      _lastReportedPlaying = ps.playing;
      unawaited(_svc.sendPlayCommand(
        ps.playing ? 'PLAY' : 'PAUSE',
        targetSongId: songId,
        progressMs: progressMs,
        playStatus: ps.playing ? 'PLAY' : 'PAUSE',
      ));
    }
  }

  /// 主动把当前播放状态广播一次（新成员加入时），
  /// 让对端（尤其后加入者）立刻对齐歌曲与进度。
  Future<void> broadcastCurrentState() async {
    final PlayerState ps = ref.read(playerProvider);
    final int songId = ps.currentTrack?.neteaseId ?? 0;
    if (songId <= 0) return;
    final int progressMs =
        ref.read(audioHandlerProvider).player.position.inMilliseconds;
    await _svc.sendPlayCommand(
      'GOTO',
      targetSongId: songId,
      progressMs: progressMs,
      playStatus: ps.playing ? 'PLAY' : 'PAUSE',
    );
    _lastReportedSongId = songId;
    _lastReportedPlaying = ps.playing;
  }

  /// 把当前播放队列公布到房间（sync/list/command REPLACE）
  Future<String?> syncQueueToRoom() async {
    final List<Track> queue = ref.read(playerProvider).queue;
    final List<int> ids = <int>[
      for (final Track t in queue)
        if (t.neteaseId != null && t.neteaseId! > 0) t.neteaseId!,
    ];
    if (ids.isEmpty) return '当前队列没有可同步的歌曲';
    return _svc.syncList(ids);
  }

  // ----------------------------------------------------------- 跟随对方

  /// 应用对方命令（GOTO 换歌 / PLAY / PAUSE / PROGRESS 拖动进度）；
  /// 进度按收到时刻补流逝时间（仅播放中），防回环窗口 3s。
  Future<void> _applyCommand(ListenPlayCommand cmd) async {
    final PlayerState ps0 = ref.read(playerProvider);
    // 加入对齐命令（服务端为新成员合成的 self/clientSeq=0 命令）：
    // 只对「加入方」生效 —— 房主不被合成命令劫持（否则开房瞬间可能被
    // 强制切到公布列表第一首）。
    final bool selfAlignment =
        cmd.userId == _svc.myUserId && cmd.clientSeq == 0;
    if (selfAlignment && _svc.isCreator) return;
    // 未装载过任何歌曲（loaded=false）时：换歌型命令（GOTO/PLAY/seek 指向
    // 不同歌）仍要应用 —— 新用户点邀请加入应当直接开播房内歌曲；
    // 播放暂停/seek 类无从作用，照旧忽略。
    final bool switchType =
        cmd.targetSongId > 0 && (cmd.isGoto || cmd.isPlay || cmd.isSeek);
    if (!ps0.loaded && !switchType) return;
    final PlayerNotifier notifier = ref.read(playerProvider.notifier);
    final PlayerState ps = ref.read(playerProvider);
    final int? currentId = ps.currentTrack?.neteaseId;

    final bool cmdPlaying =
        cmd.playStatus == 'PLAY' || cmd.isPlay || cmd.isGoto;
    final int progressMs = cmdPlaying
        ? cmd.progressMs +
            DateTime.now().difference(cmd.receivedAt).inMilliseconds
        : cmd.progressMs;

    _svc.suppressReportFor(const Duration(seconds: 3));
    state = state.copyWith(remoteSongId: cmd.targetSongId);

    // ① 换歌：GOTO 无条件跟随；PLAY/seek 且歌曲不同也先换
    final bool needSwitch = cmd.targetSongId > 0 &&
        currentId != cmd.targetSongId &&
        (cmd.isGoto || cmd.isPlay || cmd.isSeek);
    if (needSwitch) {
      int idx = -1;
      for (int i = 0; i < ps.queue.length; i++) {
        if (ps.queue[i].neteaseId == cmd.targetSongId) {
          idx = i;
          break;
        }
      }
      _following = true;
      try {
        if (idx >= 0) {
          // 同一队列内跳转（后续上一首/下一首自然同步）
          await notifier.playAt(idx);
        } else if (cmd.isGoto || selfAlignment) {
          // 队列没有 → 拉歌曲详情单曲入队（保持房内后续命令可跟；
          // 加入对齐命令同理 —— 加入者本地可能还没有房内歌曲）
          final List<Song> songs = await ref
              .read(neteaseRepositoryProvider)
              .songDetails(<int>[cmd.targetSongId]);
          if (songs.isNotEmpty) {
            await notifier.playSongs(
              <Track>[songs.first.toTrack()],
              queueTitle: '一起听',
            );
          }
        } else {
          return; // 非命令型差异不强制换歌
        }
        if (cmd.isSeek && cmdPlaying) {
          await notifier
              .seek(Duration(milliseconds: progressMs.clamp(0, 1 << 31)));
        }
        AppNotify.show('一起听：已同步对方正在播放的歌曲');
      } finally {
        _following = false;
      }
      return;
    }

    // ② 播放/暂停（命令类型决定，不靠位置差推断）
    if (cmd.isPlay && !ps.playing) {
      await notifier.playPause();
      return;
    }
    if (cmd.isPause && ps.playing) {
      await notifier.playPause();
      return;
    }

    // ③ 进度（仅同曲 seek）
    if (cmd.isSeek && currentId == cmd.targetSongId) {
      await notifier.seek(Duration(milliseconds: progressMs.clamp(0, 1 << 31)));
    }
  }

  // ----------------------------------------------------------- 成员

  /// 房间已失效（第二十六批：心跳/轮询/状态返回 488 或 inRoom=false）：
  /// 停止同步与成员循环，清空本地房间状态并给出可行动提示。
  /// （房间会话已死亡，不需要再调 /end；也避免后续心跳/轮询空转。）
  void _onRoomExpired() {
    if (!state.inRoom) return; // 幂等：轮询与心跳可能同时触发
    final bool wasCreator = state.phase == ListenRoomPhase.host;
    _stopMemberLoop();
    _lastReportedSongId = null;
    _lastReportedPlaying = null;
    unawaited(_svc.leave());
    final String notice =
        wasCreator ? '一起听房间已失效，请重新创建房间并重新邀请好友' : '一起听房间已失效，请让好友重新发起邀请后再加入';
    state = ListenRoomState(
      loggedIn: state.loggedIn,
      nickname: state.nickname,
      notice: notice,
    );
    AppNotify.show(notice);
  }

  /// 房间状态刷新回调：成员变化 → 广播当前歌（新成员 ≤10s 对齐）
  Future<void> _onRoomChanged(List<ListenRoomUser> users) async {
    final List<ListenRoomUser> prev = state.users;
    state = state.copyWith(users: users);
    // 角色与本地 phase 不一致时拉回（服务端权威，第二十七批防御纵深）
    final ListenRoomPhase expectPhase =
        _svc.isCreator ? ListenRoomPhase.host : ListenRoomPhase.guest;
    if (state.inRoom && state.phase != expectPhase && !state.busy) {
      state = state.copyWith(phase: expectPhase);
    }
    if (prev.length >= users.length) return; // 只在人数增加时广播
    final bool gainedOther = users.any((ListenRoomUser u) =>
        u.userId != _svc.myUserId &&
        prev.every((ListenRoomUser p) => p.userId != u.userId));
    if (gainedOther && _lastReportedSongId != null) {
      // 有新伙伴 → 把当前歌广播一次（对方轮询即得）
      await broadcastCurrentState();
    }
  }

  /// 服务端权威角色校正回调（status 返回的房主字段与本地冲突时触发）
  void _onRoleCorrected(bool iAmHost) {
    if (!state.inRoom || state.busy) return;
    final ListenRoomPhase expectPhase =
        iAmHost ? ListenRoomPhase.host : ListenRoomPhase.guest;
    if (state.phase != expectPhase) {
      state = state.copyWith(phase: expectPhase);
    }
  }

  /// 成员刷新循环：10s 拉一次 /listentogether/status（与心跳同频），
  /// 成员进出、人数角标、新成员广播都依赖它。
  void _startMemberLoop() {
    _memberTimer?.cancel();
    _memberTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!state.inRoom) return;
      unawaited(refreshStatus(silent: true));
    });
  }

  void _stopMemberLoop() {
    _memberTimer?.cancel();
    _memberTimer = null;
  }

  // ----------------------------------------------------------- 动作

  Future<void> refreshLogin() => _ensureLogin();

  /// 服务端会话自愈（一起听页/面板打开时调用）：
  /// 本地 idle 而服务端仍在好友房间（杀进程重开、状态清理不彻底）时，
  /// 以访客姿态恢复房间连接，防止后续误创建房间被服务端「返回所在房间」
  /// 而误置房主。已在房/请求中/未登录时不做任何事。
  Future<void> recoverIfServerRoomExists() async {
    if (state.inRoom || state.busy) return;
    if (!_svc.ensureLoginQuickCheck) return;
    final ListenServerRoom? server = await _svc.probeServerRoom();
    if (server == null || state.inRoom || state.busy) return;
    _svc.resumeRoom(
      roomId: server.roomId,
      inviterId: server.iAmHost ? _svc.myUserId : server.hostId ?? 0,
      isCreator: server.iAmHost,
    );
    state = state.copyWith(
      phase: server.iAmHost ? ListenRoomPhase.host : ListenRoomPhase.guest,
      roomId: server.roomId,
      inviterId: server.iAmHost ? _svc.myUserId : server.hostId ?? 0,
      users: server.users,
      notice: '',
    );
    _startMemberLoop();
    _svc.startSync();
    AppNotify.show(
        server.iAmHost ? '检测到你的房间仍在进行中，已恢复连接' : '检测到你仍在好友的一起听房间中，已恢复连接');
  }

  /// 创建房间（官方语义：已有房间时返回已存在的房间）
  ///
  /// ⚠️ 第二十七批「房主却是我」根治：网易 room/create 对已在房的账号
  /// 会把当前所在房间原样返回 —— 访客误触创建/重启后服务端会话仍在时
  /// 调创建，本地就会把自己误置为房主并覆盖房主队列。故创建前先做
  /// 两道检查：①本地已在房 → 直接拒绝；②服务端会话仍在（本地状态
  /// 已丢）→ 以访客姿态恢复房间连接，绝不创建新房间。
  Future<String?> createRoom() async {
    if (state.busy) return null;
    if (state.inRoom) {
      return '你已在一间一起听房间中，退出当前房间后才能创建新房间';
    }
    state = state.copyWith(phase: ListenRoomPhase.busy, notice: '');
    try {
      if (!await _ensureLogin()) {
        state = state.copyWith(phase: ListenRoomPhase.idle);
        return '请先登录网易云账号';
      }
      // 服务端残留会话检查（杀进程重开/清理不彻底时本地 idle 但服务端在房）
      final ListenServerRoom? server = await _svc.probeServerRoom();
      if (server != null) {
        // 以访客姿态恢复服务端会话（宁可为访客，不可误判房主）；
        // 只有服务端明确指认 hostId==我 才恢复为房主。
        _svc.resumeRoom(
          roomId: server.roomId,
          inviterId: server.iAmHost ? _svc.myUserId : server.hostId ?? 0,
          isCreator: server.iAmHost,
        );
        state = state.copyWith(
          phase: server.iAmHost ? ListenRoomPhase.host : ListenRoomPhase.guest,
          roomId: server.roomId,
          inviterId: server.iAmHost ? _svc.myUserId : server.hostId ?? 0,
          users: server.users,
          notice: '',
        );
        _startMemberLoop();
        _svc.startSync();
        return server.iAmHost
            ? '检测到你名下的房间仍在进行中，已恢复房间连接'
            : '你正在好友的一起听房间中，已恢复连接（未创建新房间）';
      }
      final String? err = await _svc.createRoom();
      if (err != null) {
        state = state.copyWith(phase: ListenRoomPhase.idle, notice: err);
        return err;
      }
      state = state.copyWith(
        phase: ListenRoomPhase.host,
        roomId: _svc.roomId ?? '',
        inviterId: _svc.inviterId,
        notice: '',
      );
      _startMemberLoop();
      _svc.startSync();
      // 房主开房即公布当前队列（好友加入后可拉取整列表）
      final String? syncErr = await syncQueueToRoom();
      await refreshStatus(silent: true);
      if (syncErr != null) state = state.copyWith(notice: syncErr);
      return null;
    } finally {
      if (state.busy) {
        state = state.copyWith(
            phase: _svc.inRoom
                ? (_svc.isCreator
                    ? ListenRoomPhase.host
                    : ListenRoomPhase.guest)
                : ListenRoomPhase.idle);
      }
    }
  }

  /// 加入房间（粘贴邀请串 / 深链自动带入）
  Future<String?> joinRoom(String roomId, int inviterId) async {
    if (state.busy) return null;
    final String rid = roomId.trim();
    if (rid.isEmpty) return '请输入邀请串（房间号|邀请人ID）';
    if (inviterId <= 0) return '邀请串格式应为「房间号|邀请人ID」';
    state = state.copyWith(phase: ListenRoomPhase.busy, notice: '');
    try {
      if (!await _ensureLogin()) {
        state = state.copyWith(phase: ListenRoomPhase.idle);
        return '请先登录网易云账号';
      }
      final String? err = await _svc.joinRoom(rid, inviterId);
      if (err != null) {
        // 加入失败时不能无脑回 idle：service 里可能还持有原房间
        // （换房场景 accept 被拒）—— 按 service 真实状态恢复，防漂移。
        final ListenRoomPhase fallback = _svc.inRoom
            ? (_svc.isCreator ? ListenRoomPhase.host : ListenRoomPhase.guest)
            : ListenRoomPhase.idle;
        state = state.copyWith(phase: fallback, notice: err);
        if (fallback != ListenRoomPhase.idle) {
          _startMemberLoop();
          _svc.startSync();
        }
        return err;
      }
      state = state.copyWith(
        phase: ListenRoomPhase.guest,
        roomId: rid,
        inviterId: inviterId,
        roomSongIds: const <int>[],
        notice: '',
      );
      _startMemberLoop();
      _svc.startSync();
      // 加入后立即拉房间公布列表（不知道房主放到哪首，等 GOTO 命令对齐；
      // 房主端成员刷新循环 ≤10s 也会广播当前歌）
      final List<int> ids = await _svc.fetchRoomPlaylist();
      if (ids.isNotEmpty) {
        state = state.copyWith(roomSongIds: ids);
        await refreshStatus(silent: true);
      }
      return null;
    } finally {
      if (state.busy) {
        state = state.copyWith(
            phase: _svc.inRoom
                ? (_svc.isCreator
                    ? ListenRoomPhase.host
                    : ListenRoomPhase.guest)
                : ListenRoomPhase.idle);
      }
    }
  }

  /// 解析剪贴板中的邀请信息（一起听页/面板打开时调用）
  Future<ListenInvite?> readInviteFromClipboard() async {
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String? text = data?.text;
      if (text == null || text.isEmpty) return null;
      return parseListenInvite(text);
    } catch (_) {
      return null;
    }
  }

  /// 刷新房间状态（在线成员）
  Future<void> refreshStatus({bool silent = false}) async {
    final String? err = await _svc.refreshStatus();
    if (err != null && !silent) {
      state = state.copyWith(notice: err);
    }
  }

  /// 离开/关闭房间。[end] = 房主关闭（listentogether/end）
  Future<void> leave({bool end = false}) async {
    _stopMemberLoop();
    final String? err = await _svc.leave(end: end);
    _lastReportedSongId = null;
    _lastReportedPlaying = null;
    state = ListenRoomState(
      loggedIn: state.loggedIn,
      nickname: state.nickname,
      notice: err ?? (end ? '房间已关闭' : '已退出房间'),
    );
  }

  /// 播放命令手动上报（播放页控制键：PLAY/PAUSE/PROGRESS）
  Future<void> sendManualCommand(
    String commandType, {
    required int targetSongId,
    required int progressMs,
    required String playStatus,
  }) async {
    if (!state.inRoom) return;
    _svc.suppressReportFor(const Duration(seconds: 2));
    await _svc.sendPlayCommand(
      commandType,
      targetSongId: targetSongId,
      progressMs: progressMs,
      playStatus: playStatus,
    );
  }

  /// 发送网易云私信邀请（对齐 Zephyr social.ts sendText：POST /send/text）
  Future<String?> sendPrivateInvite(int friendId, String friendName) async {
    final String rid = state.roomId;
    if (rid.isEmpty) return '请先开启一起听房间';
    final String msg = '我在用 MingMusic 和你一起听歌，点击链接加入：\n'
        '${buildListenInviteLink(rid, _svc.inviterId)}\n\n'
        '若无法点击，复制邀请串到 MingMusic「一起听 → 加入一起听」粘贴：\n'
        '$rid|${_svc.inviterId}';
    try {
      final Map<String, Object?> res = await ref.read(neteaseApiProvider).post(
          '/send/text',
          <String, String>{
            'user_ids': '$friendId',
            'msg': msg,
          },
          throwOnCode: false);
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code == 200) {
        AppNotify.success('已把一起听邀请私信给 $friendName');
        return null;
      }
      return '私信发送失败（${(res['message'] ?? 'code $code')}）';
    } catch (e) {
      return '私信发送失败：$e';
    }
  }

  /// 系统分享邀请（深链 + 邀请串全文）
  Future<void> shareInvite() async {
    final String rid = state.roomId;
    if (rid.isEmpty) return;
    await PlatformActions.shareText(buildListenShareText(rid, _svc.inviterId));
  }

  /// 复制邀请串（纯 roomId|inviterId）
  Future<void> copyInvite() async {
    final String rid = state.roomId;
    if (rid.isEmpty) return;
    await PlatformActions.shareText('$rid|${_svc.inviterId}');
  }
}

/// 一起听房间全局状态（keepAlive：进程内常驻，页面/面板/播放页共享）
final NotifierProvider<ListenRoomNotifier, ListenRoomState> listenRoomProvider =
    NotifierProvider<ListenRoomNotifier, ListenRoomState>(
        ListenRoomNotifier.new);
