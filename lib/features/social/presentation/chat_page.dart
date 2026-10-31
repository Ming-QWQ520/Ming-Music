/// 聊天页（第二十六批：私信功能，借鉴 Zephyr-Music MessageView）。
///
///  - 气泡流：我方右/对方左，双方头像（UserAvatar 首字兜底）；
///  - 5s 轮询新消息（页面打开期间），发送后立即刷新；
///  - **一起听邀请卡**：消息含邀请信息（深链/邀请串，含网易云官方
///    st.music.163.com 分享链接形态）→ 渲染成卡片，对方消息点击
///    「加入一起听」直接 joinRoom 闭环；
///  - before 分页加载更早消息（reverse 列表向上增长不跳动）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/app_notify.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/providers/auth_providers.dart' show AuthState, authProvider;
import '../../listen/providers/listen_room_provider.dart'
    show ListenInvite, listenRoomProvider;
import '../data/message_repository.dart';
import '../providers/message_providers.dart' show messageRepositoryProvider;

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    required this.uid,
    this.nickname = '',
    this.avatarUrl = '',
  });

  final int uid;
  final String nickname;
  final String avatarUrl;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<ChatMessage> _msgs = const <ChatMessage>[]; // 最新在前
  bool _loading = true;
  bool _sending = false;
  bool _loadingOlder = false;
  bool _more = true;
  String _error = '';
  Timer? _poll;
  String _myName = '';
  String _myAvatar = '';

  String get _peerName => avatarDisplayName(widget.nickname, widget.uid);

  @override
  void initState() {
    super.initState();
    unawaited(_loadMe());
    unawaited(_load());
    _poll =
        Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMe() async {
    try {
      final AuthState auth = ref.read(authProvider);
      if (!mounted) return;
      _myName = auth.profile?.nickname ?? '';
      _myAvatar = auth.profile?.avatarUrl ?? '';
    } catch (_) {}
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final List<ChatMessage> list = await ref
          .read(messageRepositoryProvider)
          .history(widget.uid, limit: 30);
      final List<ChatMessage> newestFirst = list.reversed.toList();
      if (!mounted) return;
      final bool grew = newestFirst.length > _msgs.length ||
          (newestFirst.isNotEmpty &&
              _msgs.isNotEmpty &&
              newestFirst.first.id != _msgs.first.id);
      setState(() {
        _msgs = newestFirst;
        _loading = false;
        _error = '';
        _more = list.length >= 30;
      });
      if (grew && !silent) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(0); // reverse 列表：0 = 最新消息（底部）
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!silent) _error = '$e';
      });
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_more || _msgs.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final List<ChatMessage> older = await ref
          .read(messageRepositoryProvider)
          .history(widget.uid, limit: 30, before: _msgs.last.time);
      if (!mounted) return;
      setState(() {
        // 仓库返回正序（旧→新）→ 反转接到现有列表尾部（视觉上方）
        _msgs = <ChatMessage>[..._msgs, ...older.reversed];
        _more = older.length >= 30;
        _loadingOlder = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final String? err =
        await ref.read(messageRepositoryProvider).sendText(widget.uid, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      AppNotify.show(err);
      return;
    }
    _input.clear();
    await _load(silent: true);
  }

  /// 邀请卡点击：直接加入房间（被邀请后点击即可加入）
  Future<void> _joinInvite(ListenInvite inv) async {
    final st = ref.read(listenRoomProvider);
    if (st.inRoom && st.roomId == inv.roomId) {
      AppNotify.show('已在该一起听房间中');
      return;
    }
    final String? err = await ref
        .read(listenRoomProvider.notifier)
        .joinRoom(inv.roomId, inv.inviterId);
    if (!mounted) return;
    if (err == null) {
      AppNotify.success('已加入一起听，正在同步房间');
      context.push('/listen');
    } else {
      AppNotify.show(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        leadingWidth: 40,
        title: Row(
          children: <Widget>[
            UserAvatar(
              url: widget.avatarUrl,
              nickname: widget.nickname,
              userId: widget.uid,
              radius: 16,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _peerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.4)))
                : _error.isNotEmpty
                    ? _ErrorRetry(error: _error, onRetry: () => _load())
                    : NotificationListener<ScrollNotification>(
                        onNotification: (ScrollNotification n) {
                          if (n.metrics.pixels >
                              n.metrics.maxScrollExtent - 200) {
                            unawaited(_loadOlder());
                          }
                          return false;
                        },
                        child: _msgs.isEmpty
                            ? ListView(
                                children: const <Widget>[
                                  SizedBox(height: 80),
                                  Icon(Icons.chat_bubble_outline_rounded,
                                      size: 40, color: Colors.grey),
                                  SizedBox(height: 10),
                                  Center(
                                    child: Text('还没有消息，打个招呼吧',
                                        style: TextStyle(fontSize: 13)),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                controller: _scroll,
                                reverse: true,
                                padding:
                                    const EdgeInsets.fromLTRB(14, 10, 14, 10),
                                itemCount: _msgs.length + (_more ? 1 : 0),
                                itemBuilder: (BuildContext context, int i) {
                                  if (i >= _msgs.length) {
                                    return const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 12),
                                      child: Center(
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        ),
                                      ),
                                    );
                                  }
                                  return _Bubble(
                                    msg: _msgs[i],
                                    peerName: _peerName,
                                    peerAvatar: widget.avatarUrl,
                                    peerId: widget.uid,
                                    myName: _myName,
                                    myAvatar: _myAvatar,
                                    onJoin: _joinInvite,
                                  );
                                },
                              ),
                      ),
          ),
          _InputBar(
            controller: _input,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 气泡

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.msg,
    required this.peerName,
    required this.peerAvatar,
    required this.peerId,
    required this.myName,
    required this.myAvatar,
    required this.onJoin,
  });

  final ChatMessage msg;
  final String peerName;
  final String peerAvatar;
  final int peerId;
  final String myName;
  final String myAvatar;
  final void Function(ListenInvite) onJoin;

  @override
  Widget build(BuildContext context) {
    final bool self = msg.isSelf;
    final ThemeData theme = Theme.of(context);
    final String avatarUrl = self ? myAvatar : peerAvatar;
    final String name = self ? myName : peerName;
    final int uid = self ? 0 : peerId;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            self ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: <Widget>[
          if (!self) ...<Widget>[
            UserAvatar(url: avatarUrl, nickname: name, userId: uid, radius: 16),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  self ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: <Widget>[
                if (msg.invite != null)
                  _InviteCard(
                    invite: msg.invite!,
                    self: self,
                    onJoin: () => onJoin(msg.invite!),
                  )
                else
                  Container(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.64),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: self
                          ? AppConstants.brandColor.withValues(alpha: 0.9)
                          : theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(14),
                        topRight: const Radius.circular(14),
                        bottomLeft: Radius.circular(self ? 14 : 4),
                        bottomRight: Radius.circular(self ? 4 : 14),
                      ),
                    ),
                    child: Text(
                      msg.content,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        color:
                            self ? Colors.white : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                const SizedBox(height: 3),
                Text(_fmt(msg.time),
                    style: TextStyle(
                        fontSize: 9.5,
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (self) ...<Widget>[
            const SizedBox(width: 8),
            UserAvatar(url: avatarUrl, nickname: name, userId: uid, radius: 16),
          ],
        ],
      ),
    );
  }
}

/// 一起听邀请卡（消息含邀请信息时替代普通气泡渲染；
/// 对方消息点击「加入一起听」直接加入房间 —— 被邀请后点击即可加入）
class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.invite,
    required this.self,
    required this.onJoin,
  });

  final ListenInvite invite;
  final bool self;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: MediaQuery.of(context).size.width * 0.62,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppConstants.brandColor.withValues(alpha: 0.55), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppConstants.brandColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(Icons.headset_mic_rounded,
                    size: 17, color: AppConstants.brandColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  self ? '已发出一起听邀请' : '好友邀请你一起听歌',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '房间号 ${invite.roomId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 10.5, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 9),
          if (!self)
            SizedBox(
              width: double.infinity,
              height: 32,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppConstants.brandColor,
                  padding: EdgeInsets.zero,
                ),
                onPressed: onJoin,
                child: const Text('点击加入一起听',
                    style: TextStyle(fontSize: 12.5, color: Colors.white)),
              ),
            )
          else
            Text('等待对方点击链接加入，保持房间开启',
                style: TextStyle(
                    fontSize: 10.5, color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '输入消息…',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              style: IconButton.styleFrom(
                  backgroundColor: AppConstants.brandColor),
              onPressed: sending ? null : onSend,
              icon: sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded,
                      size: 18, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('加载失败：$error',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

String _fmt(int ms) {
  if (ms <= 0) return '';
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  final String hh = d.hour.toString().padLeft(2, '0');
  final String mm = d.minute.toString().padLeft(2, '0');
  return '${d.month}/${d.day} $hh:$mm';
}
