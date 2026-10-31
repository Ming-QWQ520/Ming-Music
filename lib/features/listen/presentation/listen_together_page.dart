/// 一起听管理页（第十三批建立，第二十五批接入全局状态机闭环）。
///
/// 网易云官方「一起听」接口族（NeteaseCloudMusicApi Enhanced）：
///  - 发起：创建房间（room/create）→ 分享邀请（深链 + 邀请串双形态）；
///  - 加入：粘贴邀请串 / 好友深链点击自动带入 / 剪贴板自动识别 →
///    accept（房间号+邀请人ID）→ check；
///  - 同步闭环：命令应用与状态上报已提升至 [listenRoomProvider]
///    （全局生效，离开本页照样跟随），本页只负责房间管理与展示。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/api/netease_models.dart' show Song;
import '../../../core/widgets/cover_image.dart';
import '../../../core/widgets/app_notify.dart';
import '../../../core/widgets/user_avatar.dart'
    show UserAvatar, avatarDisplayName;
import '../../auth/presentation/login_sheet.dart' show showLoginSheet;
import '../../discover/data/netease_providers.dart'
    show neteaseRepositoryProvider;
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../providers/listen_room_provider.dart';
import '../services/listen_together_service.dart'
    show ListenTogetherService, ListenRoomUser;

/// 一起听页（/listen；深链可带 roomId/inviterId 自动加入）
class ListenTogetherPage extends ConsumerStatefulWidget {
  const ListenTogetherPage({
    super.key,
    this.initialRoomId,
    this.initialInviterId,
  });

  /// 深链 mingmusic://listen/join?roomId=X&inviterId=Y 自动带入
  final String? initialRoomId;
  final int? initialInviterId;

  @override
  ConsumerState<ListenTogetherPage> createState() => _ListenTogetherPageState();
}

class _ListenTogetherPageState extends ConsumerState<ListenTogetherPage> {
  final TextEditingController _inviteCtrl = TextEditingController();

  /// 剪贴板识别出的邀请（进入页面自动检测一次）
  ListenInvite? _pendingInvite;

  /// 深链参数已尝试自动加入（防重复触发）
  bool _autoJoinDone = false;

  List<Track> _roomSongs = const <Track>[];
  bool _pulling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ListenRoomNotifier notifier = ref.read(listenRoomProvider.notifier);
      unawaited(notifier.refreshLogin());
      // 第二十七批：打开页面先做服务端会话自愈（本地 idle 但服务端仍在
      // 好友房间 → 恢复访客连接），防止后续误创建房间被判成房主
      unawaited(notifier.recoverIfServerRoomExists());
      _handleIncomingInvite();
    });
  }

  @override
  void dispose() {
    _inviteCtrl.dispose();
    super.dispose();
  }

  /// 深链参数优先 → 自动加入；否则读剪贴板识别邀请给出确认卡
  Future<void> _handleIncomingInvite() async {
    final ListenRoomNotifier notifier = ref.read(listenRoomProvider.notifier);
    final ListenRoomState st = ref.read(listenRoomProvider);
    final String? deepRoom = widget.initialRoomId;
    final int? deepInviter = widget.initialInviterId;
    if (deepRoom != null &&
        deepRoom.isNotEmpty &&
        (deepInviter ?? 0) > 0 &&
        !_autoJoinDone &&
        !st.inRoom) {
      _autoJoinDone = true;
      _inviteCtrl.text = '$deepRoom|$deepInviter';
      final String? err = await notifier.joinRoom(deepRoom, deepInviter ?? 0);
      if (!mounted) return;
      if (err != null) {
        AppNotify.show(err);
      } else {
        AppNotify.success('已加入好友的一起听房间');
      }
      return;
    }
    if (st.inRoom) return;
    final ListenInvite? clip = await notifier.readInviteFromClipboard();
    if (!mounted || clip == null) return;
    setState(() => _pendingInvite = clip);
  }

  // ---------------------------------------------------------- 动作

  Future<void> _create() async {
    final String? err =
        await ref.read(listenRoomProvider.notifier).createRoom();
    if (!mounted) return;
    if (err != null) {
      AppNotify.show(err);
    } else {
      AppNotify.success('房间已开启，邀请好友加入吧');
      unawaited(_pullRoomPlaylist(silent: true));
    }
  }

  Future<void> _joinText() async {
    final String raw = _inviteCtrl.text.trim();
    final ListenInvite? invite = parseListenInvite(raw);
    if (invite == null) {
      AppNotify.show('邀请串格式应为「房间号|邀请人ID」或完整邀请链接');
      return;
    }
    await _join(invite);
  }

  Future<void> _join(ListenInvite invite) async {
    final String? err = await ref
        .read(listenRoomProvider.notifier)
        .joinRoom(invite.roomId, invite.inviterId);
    if (!mounted) return;
    if (err != null) {
      AppNotify.show(err);
    } else {
      setState(() => _pendingInvite = null);
      AppNotify.success('已加入一起听，正在同步房间');
      unawaited(_pullRoomPlaylist(silent: true));
    }
  }

  /// 拉取房间播放列表（sync/playlist/get → /song/detail 补全 → 展示点播）
  Future<void> _pullRoomPlaylist({bool silent = false}) async {
    if (_pulling) return;
    setState(() => _pulling = true);
    try {
      final List<int> ids = await _svc.fetchRoomPlaylist();
      if (!mounted) return;
      if (ids.isEmpty) {
        if (!silent) {
          AppNotify.show('房间暂无播放列表（对方未公布队列）');
        }
        return;
      }
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).songDetails(ids);
      if (!mounted) return;
      setState(() {
        _roomSongs = <Track>[for (final Song s in songs) s.toTrack()];
      });
      if (!silent) AppNotify.show('已拉取房间列表（${songs.length} 首）');
    } catch (_) {
      if (!silent && mounted) AppNotify.show('拉取房间列表失败，可重试');
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  ListenTogetherService get _svc => ref.read(listenServiceProvider);

  Future<void> _playRoomSong(Track t) async {
    // 房间列表点播：换到该曲并上报 GOTO（其余成员跟随）
    _svc.suppressReportFor(const Duration(seconds: 2));
    await ref.read(playerProvider.notifier).playSongs(
      <Track>[t],
      queueTitle: '一起听',
    );
  }

  Future<void> _leave({bool end = false}) async {
    await ref.read(listenRoomProvider.notifier).leave(end: end);
    if (!mounted) return;
    setState(() => _roomSongs = const <Track>[]);
    AppNotify.show(end ? '房间已关闭' : '已退出房间');
  }

  Future<void> _syncQueue() async {
    final String? err =
        await ref.read(listenRoomProvider.notifier).syncQueueToRoom();
    if (!mounted) return;
    AppNotify.show(err ?? '已把当前队列同步到房间');
  }

  // ---------------------------------------------------------- 控制三键

  Future<void> _ctrlPlay() async {
    // 修复：先取齐全部引用再 await（旧写法在 playPause 后再用 ref，
    // 页面已关闭时报 "Cannot use ref after the widget was disposed"，
    // 用户日志 22:01:39 实录）
    final PlayerNotifier player = ref.read(playerProvider.notifier);
    final ListenRoomNotifier room = ref.read(listenRoomProvider.notifier);
    final PlayerState ps = ref.read(playerProvider);
    if (ps.playing) return;
    final int songId = ps.currentTrack?.neteaseId ?? 0;
    final int pos =
        ref.read(audioHandlerProvider).player.position.inMilliseconds;
    await player.playPause();
    if (!mounted) return;
    await room.sendManualCommand(
      'PLAY',
      targetSongId: songId,
      progressMs: pos,
      playStatus: 'PLAY',
    );
  }

  Future<void> _ctrlPause() async {
    final PlayerNotifier player = ref.read(playerProvider.notifier);
    final ListenRoomNotifier room = ref.read(listenRoomProvider.notifier);
    final PlayerState ps = ref.read(playerProvider);
    if (!ps.playing) return;
    final int songId = ps.currentTrack?.neteaseId ?? 0;
    final int pos =
        ref.read(audioHandlerProvider).player.position.inMilliseconds;
    await player.playPause();
    if (!mounted) return;
    await room.sendManualCommand(
      'PAUSE',
      targetSongId: songId,
      progressMs: pos,
      playStatus: 'PAUSE',
    );
  }

  Future<void> _ctrlSeek() async {
    final PlayerState ps = ref.read(playerProvider);
    final int songId = ps.currentTrack?.neteaseId ?? 0;
    final int pos =
        ref.read(audioHandlerProvider).player.position.inMilliseconds;
    await ref.read(listenRoomProvider.notifier).sendManualCommand(
          'PROGRESS',
          targetSongId: songId,
          progressMs: pos,
          playStatus: ps.playing ? 'PLAY' : 'PAUSE',
        );
    if (!mounted) return;
    AppNotify.show('已把当前进度同步给房间');
  }

  // ---------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlayerState ps = ref.watch(playerProvider);
    final Track? track = ps.currentTrack;
    final ListenRoomState st = ref.watch(listenRoomProvider);
    final bool inRoom = st.inRoom;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('一起听',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            // 需求（第二十八批）：一起听整体处于 Beta 阶段，页面与面板均标注
            _BetaBadge(),
          ],
        ),
        actions: <Widget>[
          // 好友入口（第二十五批：为了支持一起听新增「好友」项）
          IconButton(
            tooltip: '好友',
            onPressed: () => context.push('/friends'),
            icon: const Icon(Icons.group_rounded, size: 22),
          ),
          const SizedBox(width: 6),
        ],
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
                    '网易云官方一起听：发起方创建房间，把邀请转发给好友，'
                    '好友点击链接（或粘贴邀请串）加入即可同步收听。换歌、'
                    '播放暂停与进度拖动双端实时互相同步，无需同一 Wi-Fi。',
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
            loginOk: st.loggedIn,
            nickname: st.nickname,
            onLogin: () => showLoginSheet(context),
          ),
          const SizedBox(height: 14),

          if (!st.loggedIn) ...<Widget>[
            const _HintCard('登录网易云账号后即可使用一起听'),
          ] else if (st.busy) ...<Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            ),
          ] else if (!inRoom) ...<Widget>[
            // 剪贴板邀请识别卡（好友复制了邀请串后打开本页自动出现）
            if (_pendingInvite != null) ...<Widget>[
              _InviteConfirmCard(
                invite: _pendingInvite!,
                onJoin: () => _join(_pendingInvite!),
                onDismiss: () => setState(() => _pendingInvite = null),
              ),
              const SizedBox(height: 12),
            ],
            _RoleCard(
              icon: Icons.podcasts_rounded,
              title: '发起一起听',
              subtitle: '创建房间并转发邀请，好友点击即可同步收听你的播放',
              busy: false,
              onTap: _create,
            ),
            const SizedBox(height: 12),
            _JoinCard(
              controller: _inviteCtrl,
              onJoin: _joinText,
            ),
            const SizedBox(height: 12),
          ] else ...<Widget>[
            _RoomCard(
              roomId: st.roomId,
              inviterId: st.inviterId,
              isCreator: st.phase == ListenRoomPhase.host,
              myUserId: ref.read(listenServiceProvider).myUserId,
              users: st.users,
              onShare: () =>
                  ref.read(listenRoomProvider.notifier).shareInvite(),
              onCopy: () => ref.read(listenRoomProvider.notifier).copyInvite(),
              onInviteFriends: () => context.push('/friends'),
              onRefresh: () => ref
                  .read(listenRoomProvider.notifier)
                  .refreshStatus(silent: false),
              onClose: () => _leave(end: st.phase == ListenRoomPhase.host),
            ),
            const SizedBox(height: 12),
            _SyncCard(
              busy: _pulling,
              onSyncQueue: _syncQueue,
              onPullPlaylist: () => unawaited(_pullRoomPlaylist()),
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

          if (st.notice.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(st.notice,
                  style: const TextStyle(fontSize: 12.5, height: 1.45)),
            ),
          ],

          const SizedBox(height: 18),
          Center(
            child: Text(
              inRoom && st.remoteSongId > 0
                  ? '房间正在同步：${track?.neteaseId == st.remoteSongId ? '${track!.title} - ${track.artist}' : '歌曲 ${st.remoteSongId}'}'
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

/// Beta 徽标（第二十八批需求：一起听界面增加 Beta 字样）。
/// 一起听页面与面板头部共用；描边胶囊样式，随主题色不抢主标题。
class ListenBetaBadge extends StatelessWidget {
  const ListenBetaBadge({super.key, this.fontSize = 9.5});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.primary.withValues(alpha: 0.55)),
        color: cs.primary.withValues(alpha: 0.08),
      ),
      child: Text(
        'Beta',
        style: TextStyle(
          fontSize: fontSize,
          height: 1.25,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: cs.primary.withValues(alpha: 0.95),
        ),
      ),
    );
  }
}

class _BetaBadge extends StatelessWidget {
  const _BetaBadge();

  @override
  Widget build(BuildContext context) => ListenBetaBadge();
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.loginOk,
    required this.nickname,
    required this.onLogin,
  });

  final bool loginOk;
  final String nickname;
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
                if (!loginOk) ...<Widget>[
                  const SizedBox(height: 2),
                  Text('一起听需要双方都登录网易云账号',
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

/// 剪贴板邀请确认卡
class _InviteConfirmCard extends StatelessWidget {
  const _InviteConfirmCard({
    required this.invite,
    required this.onJoin,
    required this.onDismiss,
  });

  final ListenInvite invite;
  final VoidCallback onJoin;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppConstants.brandColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppConstants.brandColor.withValues(alpha: 0.35), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.mark_email_read_rounded,
                  size: 18, color: AppConstants.brandColor),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('检测到好友的一起听邀请',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              ),
              GestureDetector(
                onTap: onDismiss,
                child: Icon(Icons.close_rounded,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('房间 ${invite.roomId} · 邀请人 ${invite.inviterId}',
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor,
              ),
              onPressed: onJoin,
              icon: const Icon(Icons.connect_without_contact_rounded, size: 17),
              label: const Text('立即加入'),
            ),
          ),
        ],
      ),
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
  });

  final TextEditingController controller;
  final VoidCallback onJoin;

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
            Text('粘贴好友分享的邀请串（房间号|邀请人ID）或邀请链接',
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
                      hintText: '例如 1873xxxxxxxxx|36547588',
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
                  onPressed: onJoin,
                  child: const Text('加入'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 房间卡：房间号 + 邀请人 + 成员列表 + 转发/复制/邀请好友 + 关闭/退出
class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.roomId,
    required this.inviterId,
    required this.isCreator,
    required this.myUserId,
    required this.users,
    required this.onShare,
    required this.onCopy,
    required this.onInviteFriends,
    required this.onRefresh,
    required this.onClose,
  });

  final String roomId;
  final int inviterId;
  final bool isCreator;
  final int myUserId;
  final List<ListenRoomUser> users;
  final VoidCallback onShare;
  final VoidCallback onCopy;
  final VoidCallback onInviteFriends;
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
                          // 需求（第二十六批）：双方头像 —— UserAvatar 统一兜底
                          Stack(
                            clipBehavior: Clip.none,
                            children: <Widget>[
                              UserAvatar(
                                url: u.avatarUrl,
                                nickname: u.nickname,
                                userId: u.userId,
                                radius: 18,
                              ),
                              if (u.userId == myUserId)
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppConstants.brandColor,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                          color: Colors.white, width: 1),
                                    ),
                                    child: const Text('我',
                                        style: TextStyle(
                                            fontSize: 8,
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800)),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            avatarDisplayName(u.nickname, u.userId),
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
                    label: const Text('转发邀请'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onInviteFriends,
                    icon: const Icon(Icons.group_rounded, size: 16),
                    label: const Text('私信邀请'),
                  ),
                ),
                const SizedBox(width: 8),
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
                    onPressed: onSyncQueue,
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
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: value));
                AppNotify.success('已复制');
              },
              child: Icon(Icons.copy_rounded,
                  size: 15,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
