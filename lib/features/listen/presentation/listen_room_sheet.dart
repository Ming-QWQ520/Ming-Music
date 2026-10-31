/// 一起听面板（第二十五批需求：播放页一起听样式与逻辑闭环）。
///
/// 播放页顶栏「一起听」键与在房状态胶囊的承载面板，与一起听管理页
/// 共享 [listenRoomProvider] 全局状态机：
///  - 未开房：发起一起听（创建房间）/ 加入一起听（粘贴邀请串，
///    打开面板时自动识别剪贴板中的邀请串/深链并给出确认卡）；
///  - 已开房：房间卡（成员头像堆叠、房间号复制）、转发邀请
///    （系统分享深链+邀请串 / 进好友页发网易云私信）、
///    公布当前队列、关闭/退出房间。
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/app_notify.dart';
import '../../../core/widgets/sheet_host.dart' show GlassSheet, showMingSheet;
import '../../../core/widgets/user_avatar.dart'
    show UserAvatar, avatarDisplayName;
import '../../auth/presentation/login_sheet.dart' show showLoginSheet;
import '../providers/listen_room_provider.dart';
import '../services/listen_together_service.dart' show ListenRoomUser;

/// 弹出一起听面板（播放页顶栏键 / 在房胶囊统一入口）
Future<void> showListenRoomSheet(BuildContext context) {
  return showMingSheet<void>(
    context,
    isScrollControlled: true,
    builder: (BuildContext ctx) => const _ListenRoomSheet(),
  );
}

class _ListenRoomSheet extends ConsumerStatefulWidget {
  const _ListenRoomSheet();

  @override
  ConsumerState<_ListenRoomSheet> createState() => _ListenRoomSheetState();
}

class _ListenRoomSheetState extends ConsumerState<_ListenRoomSheet> {
  final TextEditingController _inviteCtrl = TextEditingController();

  /// 剪贴板识别出的邀请（打开面板时读一次）
  ListenInvite? _clipInvite;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ListenRoomNotifier notifier = ref.read(listenRoomProvider.notifier);
      unawaited(notifier.refreshLogin());
      unawaited(_detectClipboardInvite());
    });
  }

  @override
  void dispose() {
    _inviteCtrl.dispose();
    super.dispose();
  }

  Future<void> _detectClipboardInvite() async {
    final ListenInvite? invite =
        await ref.read(listenRoomProvider.notifier).readInviteFromClipboard();
    if (!mounted || invite == null) return;
    // 已在房间或邀请与当前房间一致则不提示
    final ListenRoomState st = ref.read(listenRoomProvider);
    if (st.inRoom || st.busy) return;
    setState(() => _clipInvite = invite);
  }

  Future<void> _join(ListenInvite invite) async {
    final String? err = await ref.read(listenRoomProvider.notifier).joinRoom(
          invite.roomId,
          invite.inviterId,
        );
    if (!mounted) return;
    if (err != null) {
      AppNotify.show(err);
    } else {
      setState(() => _clipInvite = null);
      AppNotify.success('已加入一起听，正在同步房间');
    }
  }

  Future<void> _create() async {
    final String? err =
        await ref.read(listenRoomProvider.notifier).createRoom();
    if (!mounted) return;
    if (err != null) {
      AppNotify.show(err);
    } else {
      AppNotify.success('房间已开启，邀请好友加入吧');
    }
  }

  Future<void> _pasteInvite() async {
    final ListenInvite? invite =
        await ref.read(listenRoomProvider.notifier).readInviteFromClipboard();
    if (!mounted) return;
    if (invite != null) {
      await _join(invite);
      return;
    }
    final String raw = _inviteCtrl.text.trim();
    final ListenInvite? parsed = parseListenInvite(raw);
    if (parsed == null) {
      AppNotify.show('请粘贴邀请串（房间号|邀请人ID）或邀请链接');
      return;
    }
    await _join(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ListenRoomState st = ref.watch(listenRoomProvider);

    return GlassSheet(
      borderRadius: 24,
      maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom * 0.5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 10),
              // ---------- 拖拽条 ----------
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // ---------- 标题 ----------
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            AppConstants.brandColor,
                            Color(0xFFB31F1F)
                          ],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.headset_mic_rounded,
                          size: 20, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('一起听',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800)),
                          Text(
                            st.inRoom
                                ? (st.phase == ListenRoomPhase.host
                                    ? '房间进行中 · ${st.users.length} 人在线'
                                    : '正在跟随房主 · ${st.users.length} 人在线')
                                : '和好友同步听歌，换歌暂停实时互相同步',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // ---------- 主体 ----------
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (!st.loggedIn) ...<Widget>[
                        const _LoginCard(),
                        const SizedBox(height: 14),
                      ] else if (st.busy) ...<Widget>[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 28),
                          child: Center(
                            child: SizedBox(
                              width: 26,
                              height: 26,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.4),
                            ),
                          ),
                        ),
                      ] else if (st.inRoom) ...<Widget>[
                        _RoomPanel(st: st),
                      ] else ...<Widget>[
                        if (_clipInvite != null) ...<Widget>[
                          _InviteFoundCard(
                            invite: _clipInvite!,
                            onJoin: () => _join(_clipInvite!),
                            onDismiss: () => setState(() => _clipInvite = null),
                          ),
                          const SizedBox(height: 12),
                        ],
                        _CreateCard(onCreate: _create),
                        const SizedBox(height: 12),
                        _JoinField(
                          controller: _inviteCtrl,
                          onJoin: _pasteInvite,
                        ),
                        const SizedBox(height: 12),
                      ],
                      // ---------- 好友入口 ----------
                      _FriendsEntry(visible: st.loggedIn),
                      if (st.notice.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(st.notice,
                              style:
                                  const TextStyle(fontSize: 12, height: 1.4)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 面板内卡片

/// 登录引导卡
class _LoginCard extends StatelessWidget {
  const _LoginCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.lock_person_rounded,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('一起听需要登录网易云账号（双方都要）', style: TextStyle(fontSize: 13)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppConstants.brandColor,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            onPressed: () => showLoginSheet(context),
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }
}

/// 剪贴板邀请识别卡：好友分享的邀请串/深链复制在剪贴板时自动出现
class _InviteFoundCard extends StatelessWidget {
  const _InviteFoundCard({
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

/// 发起一起听卡
class _CreateCard extends StatelessWidget {
  const _CreateCard({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onCreate,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[AppConstants.brandColor, Color(0xFFB31F1F)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.podcasts_rounded,
                    size: 21, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('发起一起听',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700)),
                    SizedBox(height: 2),
                    Text('创建房间，把邀请转发给好友，好友点击即可加入',
                        style: TextStyle(fontSize: 11.5)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 加入输入行
class _JoinField extends StatelessWidget {
  const _JoinField({required this.controller, required this.onJoin});

  final TextEditingController controller;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.text,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: '粘贴邀请串或邀请链接',
              hintStyle: const TextStyle(fontSize: 12.5),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          onPressed: onJoin,
          child: const Text('加入'),
        ),
      ],
    );
  }
}

/// 好友页入口（第二十五批：为了支持一起听新增「好友」项）
class _FriendsEntry extends StatelessWidget {
  const _FriendsEntry({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: () {
          Navigator.of(context).pop();
          context.push('/friends');
        },
        icon: Icon(Icons.group_rounded,
            size: 17, color: theme.colorScheme.onSurfaceVariant),
        label: Text('打开好友列表，直接私信邀请',
            style: TextStyle(
                fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

// ---------------------------------------------------------------- 房间面板

/// 在房面板：状态 + 成员卡 + 转发/邀请 + 队列公布 + 退出
class _RoomPanel extends ConsumerWidget {
  const _RoomPanel({required this.st});

  final ListenRoomState st;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ListenRoomNotifier notifier = ref.read(listenRoomProvider.notifier);
    final bool isHost = st.phase == ListenRoomPhase.host;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // ---------- 房间状态卡 ----------
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppConstants.brandColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: AppConstants.brandColor.withValues(alpha: 0.28),
                width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.sync_rounded,
                      size: 17, color: AppConstants.brandColor),
                  const SizedBox(width: 6),
                  Text(isHost ? '房间已开启' : '已加入一起听',
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text('${st.users.length} 人在线',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 10),
              // 成员卡（头像堆叠 + 昵称）—— 空数据/加载失败都有兜底渲染
              _MemberStrip(users: st.users, myUserId: _myUserId(ref)),
              const SizedBox(height: 10),
              // 房间号 + 复制
              Row(
                children: <Widget>[
                  Text('房间号',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(st.roomId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2)),
                  ),
                  GestureDetector(
                    onTap: () async {
                      await Clipboard.setData(
                          ClipboardData(text: '${st.roomId}|${st.inviterId}'));
                      AppNotify.success('邀请串已复制，去粘贴给好友吧');
                    },
                    child: Icon(Icons.copy_rounded,
                        size: 15, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // ---------- 转发邀请 / 好友私信 ----------
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: AppConstants.brandColor,
                    padding: const EdgeInsets.symmetric(vertical: 11)),
                onPressed: () => notifier.shareInvite(),
                icon: const Icon(Icons.share_rounded, size: 16),
                label: const Text('转发邀请给好友'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 11)),
                onPressed: () {
                  Navigator.of(context).pop();
                  context.push('/friends');
                },
                icon: const Icon(Icons.group_rounded, size: 16),
                label: const Text('私信邀请'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ---------- 队列公布 / 退出 ----------
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10)),
                onPressed: () async {
                  final String? err = await notifier.syncQueueToRoom();
                  AppNotify.show(err ?? '已把当前队列公布到房间');
                },
                icon: const Icon(Icons.playlist_add_check_rounded, size: 16),
                label: const Text('公布当前队列', style: TextStyle(fontSize: 12.5)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    padding: const EdgeInsets.symmetric(vertical: 10)),
                onPressed: () async {
                  await notifier.leave(end: isHost);
                  AppNotify.show(isHost ? '房间已关闭' : '已退出房间');
                },
                icon: const Icon(Icons.exit_to_app_rounded, size: 16),
                label: Text(isHost ? '关闭房间' : '退出房间',
                    style: const TextStyle(fontSize: 12.5)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  int _myUserId(WidgetRef ref) => ref.read(listenServiceProvider).myUserId;
}

/// 成员头像堆叠（正常渲染保证：空头像/加载失败/超长昵称都有兜底）
class _MemberStrip extends StatelessWidget {
  const _MemberStrip({required this.users, required this.myUserId});

  final List<ListenRoomUser> users;
  final int myUserId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (users.isEmpty) {
      return Row(
        children: <Widget>[
          Icon(Icons.person_search_rounded,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('等待好友加入…',
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
        ],
      );
    }
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: users.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (BuildContext context, int index) {
          final ListenRoomUser u = users[index];
          final bool isMe = u.userId == myUserId;
          return SizedBox(
            width: 60,
            child: Column(
              children: <Widget>[
                // 需求（第二十六批）：双方头像 —— UserAvatar 统一兜底
                // （无头像/加载失败/匿名号昵称为空 → 首字彩色圆）
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    UserAvatar(
                      url: u.avatarUrl,
                      nickname: u.nickname,
                      userId: u.userId,
                      radius: 17,
                    ),
                    if (isMe)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppConstants.brandColor,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white, width: 1),
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
                  style: TextStyle(
                    fontSize: 10.5,
                    color: isMe
                        ? AppConstants.brandColor
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: isMe ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
