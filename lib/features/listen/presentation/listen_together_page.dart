/// 一起听 —— 网易云官方「一起听」接口（第十三批需求：对齐
/// musicapi.mingqwq.top/listen_together_host.html 官方示例流程，
/// 替换旧局域网方案 —— 两端登录网易云账号即可，无需同一 Wi-Fi）。
///
///  - 发起一起听：创建房间（room/create）→ 分享邀请串「房间号|邀请人ID」
///    （对齐官方分享链接语义 st.music.163.com/listen-together/share）；
///  - 加入一起听：粘贴邀请串 → accept（需邀请者 id 一对凭据）→ check；
///  - 双端对称同步：换歌/播放暂停经 play/command 上报（GOTO/PLAY/PAUSE），
///    每 2s 轮询 sync/playlist/get 读对方命令（serverSeq 判新旧）；
///    心跳 10s 上报本机状态保活在房；
///  - 队列公布：把当前播放队列 REPLACE 到房间（sync/list/command），
///    对方拉取后可在同一列表里继续上/下一首；
///  - 官方语义：sync/playlist/get 读到的是「对方」的命令，单人房间
///    返回空 data（自测需要两个账号）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/api/netease_models.dart' show Song;
import '../../../core/utils/platform_actions.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/presentation/login_sheet.dart' show showLoginSheet;
import '../../discover/data/netease_providers.dart'
    show neteaseApiProvider, neteaseRepositoryProvider;
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../services/listen_together_service.dart';

/// 全局唯一同步服务实例（复用网易云 API 客户端与登录 cookie）
final Provider<ListenTogetherService> listenServiceProvider =
    Provider<ListenTogetherService>(
        (Ref ref) => ListenTogetherService(ref.read(neteaseApiProvider)));

class ListenTogetherPage extends ConsumerStatefulWidget {
  const ListenTogetherPage({super.key});

  @override
  ConsumerState<ListenTogetherPage> createState() => _ListenTogetherPageState();
}

class _ListenTogetherPageState extends ConsumerState<ListenTogetherPage> {
  bool _busy = false;
  bool _loginOk = false;
  String _loginError = '';
  List<ListenRoomUser> _users = const <ListenRoomUser>[];
  String _notice = '';
  int _remoteSongId = 0;

  /// 跟随换歌进行中（抑制本机状态上报，避免把对方命令反向报回去）
  bool _following = false;

  /// 上次上报的歌曲/播放状态（变化才上报）
  int? _lastReportedSongId;
  bool? _lastReportedPlaying;

  final TextEditingController _inviteCtrl = TextEditingController();

  ListenTogetherService get _svc => ref.read(listenServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _svc.onCommand = _applyCommand;
      _svc.onRoomChanged = (List<ListenRoomUser> users) {
        if (mounted) setState(() => _users = users);
      };
      _svc.statusSupplier = () {
        final PlayerState ps = ref.read(playerProvider);
        return (
          songId: ps.currentTrack?.neteaseId ?? 0,
          playing: ps.playing,
          progressMs:
              ref.read(audioHandlerProvider).player.position.inMilliseconds,
        );
      };
      // 本机播放状态变化 → 上报命令（防回环窗口内跳过）
      ref.listenManual<PlayerState>(playerProvider, (_, PlayerState ps) {
        _reportLocalState(ps);
      });
      _bootstrap();
    });
  }

  @override
  void dispose() {
    // 离开页面：保留房间（后台继续同步轮询），仅解绑 UI 回调
    _svc.onCommand = null;
    _svc.onRoomChanged = null;
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final String? err = await _svc.ensureLogin();
    if (!mounted) return;
    setState(() {
      _loginOk = err == null;
      _loginError = err ?? '';
    });
    // 恢复场景：service 已在房间（快速切换页面回来）
    if (err == null && _svc.inRoom && !_svc.isSyncing) {
      await _svc.startSync();
      if (mounted) setState(() {});
    }
  }

  // ---------------------------------------------------------- 本机上报

  /// 播放状态变化上报（换歌 → GOTO；播放暂停 → PLAY/PAUSE；
  /// 以播放器实际状态为准，变化才上报）
  void _reportLocalState(PlayerState ps) {
    if (!mounted || _following) return;
    if (!_svc.inRoom || _svc.reportSuppressed) return;
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

  // ---------------------------------------------------------- 跟随对方

  /// 应用对方命令（GOTO 换歌 / PLAY / PAUSE / PROGRESS 拖动进度）；
  /// 进度按收到时刻补流逝时间（仅播放中），防回环窗口 3s。
  Future<void> _applyCommand(ListenPlayCommand cmd) async {
    if (!mounted || !ref.read(playerProvider).loaded) return;
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
    if (mounted) setState(() => _remoteSongId = cmd.targetSongId);

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
          // 同一队列内跳转（对方也在这个列表里，后续上一首/下一首自然同步）
          await notifier.playAt(idx);
        } else if (cmd.isGoto) {
          // 队列没有 → 拉歌曲详情单曲入队（保持房内后续命令可跟）
          final List<Song> songs = await ref
              .read(neteaseRepositoryProvider)
              .songDetails(<int>[cmd.targetSongId]);
          if (songs.isNotEmpty && mounted) {
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

  // ---------------------------------------------------------- 动作

  Future<void> _create() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String? err = await _svc.createRoom();
      if (!mounted) return;
      if (err != null) {
        setState(() => _notice = err);
      } else {
        setState(() => _notice = '');
        await _svc.refreshStatus();
        await _svc.startSync();
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    if (_busy) return;
    final String raw = _inviteCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _notice = '请粘贴邀请串（房间号|邀请人ID）');
      return;
    }
    final List<String> parts = raw.split('|');
    final String roomId = parts.first.trim();
    final int inviterId =
        parts.length > 1 ? int.tryParse(parts[1].trim()) ?? 0 : 0;
    if (inviterId <= 0) {
      setState(() => _notice = '邀请串格式应为「房间号|邀请人ID」');
      return;
    }
    setState(() {
      _busy = true;
      _notice = '';
    });
    try {
      final String? err = await _svc.joinRoom(roomId, inviterId);
      if (!mounted) return;
      if (err != null) {
        setState(() => _notice = err);
      } else {
        await _svc.refreshStatus();
        await _svc.startSync();
        if (mounted) {
          setState(() {});
          _toast('已加入一起听，正在同步房间');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 把当前播放队列公布到房间（sync/list/command REPLACE）
  Future<void> _syncQueue() async {
    final List<Track> queue = ref.read(playerProvider).queue;
    final List<int> ids = <int>[
      for (final Track t in queue)
        if (t.neteaseId != null && t.neteaseId! > 0) t.neteaseId!,
    ];
    if (ids.isEmpty) {
      setState(() => _notice = '当前队列没有可同步的歌曲');
      return;
    }
    final String? err = await _svc.syncList(ids);
    if (!mounted) return;
    setState(() => _notice = err ?? '已把当前队列同步到房间（${ids.length} 首）');
  }

  /// 拉取房间播放列表（demo 同款：sync/playlist/get → displayList →
  /// /song/detail 补全 → 展示并可直接播放跟随）
  Future<void> _pullRoomPlaylist() async {
    setState(() => _busy = true);
    try {
      final List<int> ids = await _svc.fetchRoomPlaylist();
      if (!mounted) return;
      if (ids.isEmpty) {
        setState(() => _notice = '房间暂无播放列表（对方未公布队列）');
        return;
      }
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).songDetails(ids);
      if (!mounted) return;
      if (songs.isEmpty) {
        setState(() => _notice = '房间列表歌曲详情获取失败');
        return;
      }
      setState(() {
        _notice = '已拉取房间列表（${songs.length} 首）';
        _roomSongs = <Track>[for (final Song s in songs) s.toTrack()];
      });
    } catch (e) {
      if (mounted) setState(() => _notice = '拉取失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Track> _roomSongs = const <Track>[];

  Future<void> _playRoomSong(Track t) async {
    // 房间列表点播：换到该曲并上报 GOTO（其余成员跟随）
    _svc.suppressReportFor(const Duration(seconds: 2));
    await ref.read(playerProvider.notifier).playSongs(
      <Track>[t],
      queueTitle: '一起听',
    );
  }

  Future<void> _leave({bool end = false}) async {
    final String? err = await _svc.leave(end: end);
    if (!mounted) return;
    setState(() {
      _users = const <ListenRoomUser>[];
      _roomSongs = const <Track>[];
      _notice = err ?? (end ? '房间已关闭' : '已退出房间');
      _lastReportedSongId = null;
      _lastReportedPlaying = null;
    });
  }

  Future<void> _refreshRoom() async {
    final String? err = await _svc.refreshStatus();
    if (!mounted) return;
    if (err != null) setState(() => _notice = err);
  }

  Future<void> _shareInvite() async {
    final String? rid = _svc.roomId;
    if (rid == null) return;
    final String invite = '$rid|${_svc.inviterId}';
    await PlatformActions.shareText(
      '【MingMusic 一起听】把邀请串粘贴到「加入一起听」即可同步收听：\n$invite',
    );
  }

  Future<void> _copyInvite() async {
    final String? rid = _svc.roomId;
    if (rid == null) return;
    await PlatformActions.shareText('$rid|${_svc.inviterId}');
  }

  // ---------------------------------------------------------- 控制三键

  Future<void> _ctrlPlay() async {
    final PlayerState ps = ref.read(playerProvider);
    if (!ps.playing) {
      _svc.suppressReportFor(const Duration(seconds: 2));
      await ref.read(playerProvider.notifier).playPause();
      final int songId = ps.currentTrack?.neteaseId ?? 0;
      final int pos =
          ref.read(audioHandlerProvider).player.position.inMilliseconds;
      unawaited(_svc.sendPlayCommand('PLAY',
          targetSongId: songId, progressMs: pos, playStatus: 'PLAY'));
    }
  }

  Future<void> _ctrlPause() async {
    final PlayerState ps = ref.read(playerProvider);
    if (ps.playing) {
      _svc.suppressReportFor(const Duration(seconds: 2));
      await ref.read(playerProvider.notifier).playPause();
      final int songId = ps.currentTrack?.neteaseId ?? 0;
      final int pos =
          ref.read(audioHandlerProvider).player.position.inMilliseconds;
      unawaited(_svc.sendPlayCommand('PAUSE',
          targetSongId: songId, progressMs: pos, playStatus: 'PAUSE'));
    }
  }

  Future<void> _ctrlSeek() async {
    final PlayerState ps = ref.read(playerProvider);
    final int songId = ps.currentTrack?.neteaseId ?? 0;
    final int pos =
        ref.read(audioHandlerProvider).player.position.inMilliseconds;
    _svc.suppressReportFor(const Duration(seconds: 2));
    final String? err = await _svc.sendPlayCommand('PROGRESS',
        targetSongId: songId, progressMs: pos, playStatus: 'PLAY');
    if (!mounted) return;
    setState(() => _notice = err ?? '已把当前进度同步给房间');
  }

  // ---------------------------------------------------------- build

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), duration: const Duration(milliseconds: 1800)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlayerState ps = ref.watch(playerProvider);
    final Track? track = ps.currentTrack;
    final bool inRoom = _svc.inRoom;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('一起听',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          // 说明卡
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.22),
                  width: 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.headphones_rounded,
                    size: 18,
                    color: theme.colorScheme.primary.withValues(alpha: 0.9)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '网易云官方一起听：发起方创建房间，把邀请串发给好友，'
                    '好友粘贴加入即可同步收听。换歌、播放暂停与进度拖动'
                    '双端实时互相同步，无需同一 Wi-Fi。',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: theme.colorScheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 登录状态卡
          _AccountCard(
            loginOk: _loginOk,
            nickname: _svc.nickname,
            error: _loginError,
            onLogin: () => showLoginSheet(context),
          ),
          const SizedBox(height: 14),

          if (!_loginOk) ...<Widget>[
            _HintCard('登录网易云账号后即可使用一起听'),
          ] else if (!inRoom) ...<Widget>[
            _RoleCard(
              icon: Icons.podcasts_rounded,
              title: '发起一起听',
              subtitle: '创建房间并分享邀请串，好友加入后同步收听你的播放',
              busy: _busy,
              onTap: _create,
            ),
            const SizedBox(height: 12),
            _JoinCard(
              controller: _inviteCtrl,
              busy: _busy,
              onJoin: _join,
            ),
          ] else ...<Widget>[
            _RoomCard(
              roomId: _svc.roomId ?? '',
              inviterId: _svc.inviterId,
              isCreator: _svc.isCreator,
              users: _users,
              onShare: _shareInvite,
              onCopy: _copyInvite,
              onRefresh: _refreshRoom,
              onClose: () => _leave(end: _svc.isCreator),
            ),
            const SizedBox(height: 12),
            _SyncCard(
              busy: _busy,
              onSyncQueue: _syncQueue,
              onPullPlaylist: _pullRoomPlaylist,
            ),
            if (_roomSongs.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              _RoomPlaylistCard(
                tracks: _roomSongs,
                currentId: track?.neteaseId ?? 0,
                onTap: _playRoomSong,
              ),
            ],
            const SizedBox(height: 12),
            _ControlCard(
              playing: ps.playing,
              onPlay: _ctrlPlay,
              onPause: _ctrlPause,
              onSeek: _ctrlSeek,
            ),
          ],

          if (_notice.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_notice,
                  style: const TextStyle(fontSize: 12.5, height: 1.45)),
            ),
          ],

          const SizedBox(height: 18),
          Center(
            child: Text(
              inRoom && _remoteSongId > 0
                  ? '房间正在同步：${track?.neteaseId == _remoteSongId ? '${track!.title} - ${track.artist}' : '歌曲 $_remoteSongId'}'
                  : '当前播放：${track == null ? '未在播放' : '${track.title} - ${track.artist}'}',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 组件

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.loginOk,
    required this.nickname,
    required this.error,
    required this.onLogin,
  });

  final bool loginOk;
  final String nickname;
  final String error;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 18,
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14),
            child: Icon(
              loginOk ? Icons.check_circle_rounded : Icons.person_rounded,
              size: 20,
              color: loginOk
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(loginOk ? '已登录：$nickname' : '未登录网易云账号',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                if (error.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(error,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          if (!loginOk)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onPressed: onLogin,
              child: const Text('去登录'),
            ),
        ],
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.busy,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[AppConstants.brandColor, Color(0xFFB31F1F)],
                  ),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, size: 23, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title,
                        style: const TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.chevron_right_rounded,
                    size: 22, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _JoinCard extends StatelessWidget {
  const _JoinCard({
    required this.controller,
    required this.onJoin,
    required this.busy,
  });

  final TextEditingController controller;
  final VoidCallback onJoin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('加入一起听',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('粘贴好友分享的邀请串（房间号|邀请人ID）',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: controller,
                    keyboardType: TextInputType.text,
                    decoration: InputDecoration(
                      hintText: '例如 1873xxxxxxxxx|365xxx88',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppConstants.brandColor,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12)),
                  onPressed: busy ? null : onJoin,
                  child: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('加入'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 房间卡：房间号 + 邀请人 + 成员列表 + 分享/复制/刷新 + 关闭/退出
class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.roomId,
    required this.inviterId,
    required this.isCreator,
    required this.users,
    required this.onShare,
    required this.onCopy,
    required this.onRefresh,
    required this.onClose,
  });

  final String roomId;
  final int inviterId;
  final bool isCreator;
  final List<ListenRoomUser> users;
  final VoidCallback onShare;
  final VoidCallback onCopy;
  final VoidCallback onRefresh;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.sync_rounded,
                    size: 18, color: AppConstants.brandColor),
                const SizedBox(width: 6),
                Text(isCreator ? '房间已开启' : '已加入一起听',
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  tooltip: '刷新房间状态',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            _KV('房间号', roomId, copyable: true),
            _KV('邀请人', '$inviterId'),
            _KV('成员', users.isEmpty ? '等待好友加入…' : '${users.length} 人在线'),
            if (users.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  for (final ListenRoomUser u in users)
                    SizedBox(
                      width: 68,
                      child: Column(
                        children: <Widget>[
                          CircleAvatar(
                            radius: 18,
                            backgroundImage: u.avatarUrl.isNotEmpty
                                ? NetworkImage(u.avatarUrl)
                                : null,
                            child: u.avatarUrl.isEmpty
                                ? const Icon(Icons.person_rounded, size: 18)
                                : null,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            u.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10.5),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppConstants.brandColor),
                    onPressed: onShare,
                    icon: const Icon(Icons.share_rounded, size: 16),
                    label: const Text('分享邀请串'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onClose,
                    child: Text(isCreator ? '关闭房间' : '退出房间'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 队列同步卡（对齐 demo「加载歌单」语义）
class _SyncCard extends StatelessWidget {
  const _SyncCard({
    required this.busy,
    required this.onSyncQueue,
    required this.onPullPlaylist,
  });

  final bool busy;
  final VoidCallback onSyncQueue;
  final VoidCallback onPullPlaylist;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('播放列表同步',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('把当前队列公布到房间，或拉取对方公布的列表',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onSyncQueue,
                    icon: const Icon(Icons.upload_rounded, size: 16),
                    label: const Text('同步当前队列'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onPullPlaylist,
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download_rounded, size: 16),
                    label: const Text('拉取房间列表'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 房间播放列表（拉取后展示，点歌即播并上报 GOTO）
class _RoomPlaylistCard extends StatelessWidget {
  const _RoomPlaylistCard({
    required this.tracks,
    required this.currentId,
    required this.onTap,
  });

  final List<Track> tracks;
  final int currentId;
  final void Function(Track) onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
              child: Text('房间播放列表（${tracks.length} 首，点击播放）',
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
            SizedBox(
              height: 216,
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (BuildContext context, int index) {
                  final Track t = tracks[index];
                  final bool active =
                      t.neteaseId != null && t.neteaseId == currentId;
                  return ListTile(
                    dense: true,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CoverImage(src: t.cover, size: 40, radius: 6),
                    ),
                    title: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                        color: active ? AppConstants.brandColor : null,
                      ),
                    ),
                    subtitle: Text(t.artist,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => onTap(t),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放控制卡（对齐 demo：播放 / 暂停 / 同步进度三键）
class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.playing,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
  });

  final bool playing;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onSeek;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('播放控制（同步到房间）',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppConstants.brandColor),
                    onPressed: playing ? null : onPlay,
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('播放'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor:
                            Theme.of(context).colorScheme.onSurface),
                    onPressed: playing ? onPause : null,
                    icon: const Icon(Icons.pause_rounded, size: 18),
                    label: const Text('暂停'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onSeek,
                    icon: const Icon(Icons.sync_alt_rounded, size: 16),
                    label: const Text('同步进度'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.label, this.value, {this.copyable = false});

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 68,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          if (copyable)
            GestureDetector(
              onTap: () => PlatformActions.shareText(value),
              child: Icon(Icons.copy_rounded,
                  size: 15,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
