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

  /// 上次上报的队列签名（变化才 REPLACE，第二十八批「添加歌曲/切换
  /// 歌单立即同步」：房内任何一端队列变化都自动公布给房间）
  String? _lastQueueKey;

  /// 服务端房间队列视图（poll/fetch 读到的 displayList 签名，
  /// 采纳侧基准：本机与服务端一致时不采纳、也不重发布）
  String _roomQueueKey = '';

  /// 队列 REPLACE 防抖（拖动添加多首时只发一次）
  Timer? _queueSyncDebounce;

  /// 队列自动同步禁止窗口（跟随对方换歌导致的本机队列变化不回传，
  /// 否则加入方会把单曲队列 REPLACE 覆盖房主队列）
  DateTime _suppressQueueSyncUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void _suppressQueueSyncFor(Duration duration) {
    _suppressQueueSyncUntil = DateTime.now().add(duration);
  }

  bool get _queueSyncSuppressed =>
      DateTime.now().isBefore(_suppressQueueSyncUntil);

  /// 队列签名（仅取有效网易云 id；本地曲目不参与同步）
  String _queueKeyOf(List<Track> queue) => <String>[
        for (final Track t in queue)
          if (t.neteaseId != null && t.neteaseId! > 0) '${t.neteaseId}',
      ].join(',');

  String _currentQueueKey() => _queueKeyOf(ref.read(playerProvider).queue);

  @override
  ListenRoomState build() {
    // 回调注册一次（Notifier keepAlive，生命周期=进程）
    _svc.onCommand = _applyCommand;
    _svc.onRoomChanged = _onRoomChanged;
    _svc.onRoomExpired = _onRoomExpired;
    _svc.onRoleCorrected = _onRoleCorrected;
    _svc.onRoomPlaylist = _onRoomPlaylist;
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
      _reportQueueIfNeeded(ps);
    });
    ref.onDispose(() {
      _memberTimer?.cancel();
      _memberTimer = null;
      _queueSyncDebounce?.cancel();
      _queueSyncDebounce = null;
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

  /// 队列变化自动公布（第二十八批「添加歌曲/切换歌单立即同步」）：
  /// 房内任一端把歌曲加入队列/播放新歌单 → 队列签名变化 → 防抖 800ms
  /// 后 REPLACE 给房间，对端轮询读到 displayList 变化后采纳。
  ///
  /// 闭环与防乒乓：
  ///  - 跟随对方命令引起的队列变化（单曲入队/采纳房间列表）：签名仍
  ///    会钉进基线（[._lastQueueKey]），但不发布 —— 窗口过后不再误报；
  ///  - 本机签名与 `_roomQueueKey`（服务端视图）一致时不重发布 ——
  ///    对端采纳后签名与服务端一致，两边都不会再发，收敛无回环。
  void _reportQueueIfNeeded(PlayerState ps) {
    if (!state.inRoom) return;
    final String key = _queueKeyOf(ps.queue);
    final bool changed = key != _lastQueueKey;
    _lastQueueKey = key; // 基线总是钉住：跟随/抑制期间的变化不回传
    if (!changed || _following || _queueSyncSuppressed) return;
    _queueSyncDebounce?.cancel();
    _queueSyncDebounce = Timer(const Duration(milliseconds: 800), () {
      if (!state.inRoom || _following || _queueSyncSuppressed) return;
      // 防抖窗口内队列又变了（采纳房间列表/跟随换歌）：作废本次发布，
      // 最新变化会走自己的发布流程，避免旧快照覆盖新状态
      if (_currentQueueKey() != key) return;
      unawaited(_svc
          .syncList(<int>[
        for (final String s in key.split(','))
          if (s.isNotEmpty) int.tryParse(s) ?? 0,
      ]..removeWhere((int v) => v <= 0))
          .then((String? err) {
        if (err == null) {
          _roomQueueKey = key; // 发布成功：服务端视图即本机签名
        } else {
          _lastQueueKey = null; // 失败：下次变化重试发布
        }
      }));
    });
  }

  /// 服务端房间队列变化（轮询读到 displayList 变化 / 加入后首次拉取）
  /// → 把对方公布的队列采纳到本机（「切换歌单/添加歌曲立即同步」的
  /// 接收侧）。
  void _onRoomPlaylist(List<int> ids) {
    if (!state.inRoom || ids.isEmpty) return;
    final String key = ids.join(',');
    // 自发布回声：服务端视图 == 我们刚 REPLACE 的内容（displayList 轮询
    // 有延迟，期间用户可能又编辑了队列 —— 若照单全收会回滚用户刚加的歌）
    final bool selfEcho = key == _roomQueueKey;
    _roomQueueKey = key;
    state = state.copyWith(roomSongIds: ids);
    final PlayerState ps = ref.read(playerProvider);
    if (selfEcho || _queueKeyOf(ps.queue) == key) {
      _lastQueueKey = key; // 不采纳：自发布回声或本机已一致
      return;
    }
    if (_following || _queueSyncSuppressed) return; // 跟随中不采纳，防打架
    unawaited(_adoptRoomQueue(ids));
  }

  /// 把房间公布的队列采纳为本机队列：当前歌仍在列表内 → 定位到该歌
  /// 并保持进度续播；不在 → 装载队列但不自动开播（等对方 GOTO/
  /// 加入对齐命令选歌，避免抢播错歌）。
  Future<void> _adoptRoomQueue(List<int> ids) async {
    if (ids.isEmpty) return;
    final PlayerState ps0 = ref.read(playerProvider);
    final int currentId = ps0.currentTrack?.neteaseId ?? 0;
    final Duration pos = ref.read(audioHandlerProvider).player.position;
    final bool wasPlaying = ps0.playing;
    try {
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).songDetails(ids);
      if (songs.isEmpty || !state.inRoom) return;
      final Map<int, Song> byId = <int, Song>{
        for (final Song s in songs) s.id: s,
      };
      final List<Track> tracks = <Track>[
        for (final int id in ids)
          if (byId[id] != null) byId[id]!.toTrack(),
      ];
      if (tracks.isEmpty) return;
      int startIdx = 0;
      for (int i = 0; i < tracks.length; i++) {
        if (tracks[i].neteaseId == currentId) {
          startIdx = i;
          break;
        }
      }
      final bool sameSong = ps0.loaded &&
          currentId > 0 &&
          tracks[startIdx].neteaseId == currentId;
      _following = true;
      try {
        await ref.read(playerProvider.notifier).playSongs(
              tracks,
              startIndex: startIdx,
              queueTitle: '一起听',
              autoPlay: sameSong,
            );
        if (sameSong) {
          if (pos > Duration.zero) {
            await ref.read(playerProvider.notifier).seek(pos);
          }
          if (!wasPlaying) {
            await ref.read(playerProvider.notifier).pause();
          }
        }
      } finally {
        _following = false;
      }
      // 防回环：采纳后的队列签名钉进基线（PlayerState 后续 emissions
      // 不再把采纳结果反向 REPLACE 给房间）
      _lastQueueKey = _currentQueueKey();
    } catch (e) {
      debugListenLog('adoptRoomQueue 失败: $e');
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
    final String? err = await _svc.syncList(ids);
    if (err == null) {
      _lastQueueKey = ids.join(',');
      _roomQueueKey = _lastQueueKey!; // 发布成功：服务端视图即本机队列
    }
    return err;
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
    _suppressQueueSyncFor(const Duration(seconds: 8));
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
        // 跟随刚结束：把影子队列签名钉进基线 —— 后续 emissions 不再
        // 把单曲队列反向 REPLACE 覆盖对方列表（第二十八批根治）
        _lastQueueKey = _currentQueueKey();
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
    _lastQueueKey = null;
    _roomQueueKey = '';
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
  /// 本地 idle 而服务端仍在房间（杀进程重开、状态清理不彻底）时，
  /// **仅当房间看起来还活着**（除我之外还有真实成员）才以恢复姿态
  /// 回填连接；只有我一个人挂在里面的「僵尸房」绝不恢复 —— 否则本端
  /// 心跳会把僵尸房持续保活，之后创建新房间永远被「已有房间」挡住
  /// （第二十八批「无法创建房间→显示已有房间」死锁的根因）。
  Future<void> recoverIfServerRoomExists() async {
    if (state.inRoom || state.busy) return;
    if (!_svc.ensureLoginQuickCheck) return;
    final ListenServerRoom? server = await _svc.probeServerRoom();
    if (server == null || state.inRoom || state.busy) return;
    final bool alive =
        server.users.any((ListenRoomUser u) => u.userId != _svc.myUserId);
    if (!alive) {
      // 僵尸房：不恢复、不心跳（让它自然过期，创建流程会清场）。
      // 房主态可以直接 /end 掉，给创建新房间腾路。
      if (server.iAmHost) {
        await _svc.endRoomById(server.roomId);
      } else {
        _svc.markVacatedRoom(server.roomId);
      }
      return;
    }
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
    _lastQueueKey = null; // 重置队列签名：恢复后允许下次变化触发 REPLACE
    _roomQueueKey = '';
    _startMemberLoop();
    _svc.startSync();
    AppNotify.show(
        server.iAmHost ? '检测到你的房间仍在进行中，已恢复连接' : '检测到你仍在好友的一起听房间中，已恢复连接');
  }

  /// 创建房间（官方语义：已有房间时返回已存在的房间）
  ///
  /// ⚠️ 第二十八批「无法创建房间→显示已有房间」死锁根治：旧版创建前
  /// 探测到服务端残留会话就恢复连接并开始心跳 —— 僵尸房被本端持续
  /// 保活，之后每次创建都被「已有房间」挡住，用户永远开不了新房间。
  /// 现在的语义：用户点「创建」就是要一间新房间 ——
  ///  ① 服务端残留的旧房间且我是房主 → 直接 /end 清场后创建；
  ///  ② 残留的是好友的房间 → 登记清场（不心跳、不恢复）后创建；
  ///  ③ create 响应返回旧房间号（会话残留回显）→ 拒绝认领，提示
  ///     稍后再试，绝不误置 isCreator=true（「房主却是我」防线）。
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
      // 服务端残留会话清场：用户点创建 = 要新房间，旧房间一律让路
      final ListenServerRoom? server = await _svc.probeServerRoom();
      if (server != null) {
        if (server.iAmHost) {
          // 我名下的旧房间：直接关闭（好友早已不在，房间无人使用）
          await _svc.endRoomById(server.roomId);
        } else {
          // 好友的房间：不心跳不恢复，登记后等服务端自然过期；
          // create 若回显该房间号会被 service 拦下
          _svc.markVacatedRoom(server.roomId);
        }
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
      _lastQueueKey = _currentQueueKey(); // 以当前队列为基线，避免陈旧队列误判变化
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
      _lastQueueKey = _currentQueueKey(); // 以本机队列现状为基线，加入后只有真变化才 REPLACE
      _startMemberLoop();
      _svc.startSync();
      // 加入后立即拉房间公布列表并采纳为本机队列（「切换歌单立即同步」）：
      // 当前歌在列表内 → 定位续播；不在 → 装载不自动播，等 GOTO/
      // 加入对齐命令选歌（房主端成员刷新循环 ≤10s 也会广播当前歌）
      final List<int> ids = await _svc.fetchRoomPlaylist();
      if (ids.isNotEmpty) {
        _roomQueueKey = ids.join(',');
        state = state.copyWith(roomSongIds: ids);
        await _adoptRoomQueue(ids);
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
    _queueSyncDebounce?.cancel();
    _queueSyncDebounce = null;
    final String? err = await _svc.leave(end: end);
    _lastReportedSongId = null;
    _lastReportedPlaying = null;
    _lastQueueKey = null;
    _roomQueueKey = '';
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

  /// 立即把本机当前播放进度上报给房间（第二十八批「任何操作都要立即
  /// 同步」：播放页拖动进度条松手时调用，无需等状态变化监听）
  Future<void> reportSeekNow() async {
    if (!state.inRoom) return;
    final PlayerState ps = ref.read(playerProvider);
    final int songId = ps.currentTrack?.neteaseId ?? 0;
    if (songId <= 0) return;
    final int progressMs =
        ref.read(audioHandlerProvider).player.position.inMilliseconds;
    await sendManualCommand(
      'PROGRESS',
      targetSongId: songId,
      progressMs: progressMs,
      playStatus: ps.playing ? 'PLAY' : 'PAUSE',
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
