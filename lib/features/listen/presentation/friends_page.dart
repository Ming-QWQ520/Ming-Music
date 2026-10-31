/// 好友页（第二十五批需求：为了支持一起听，新增「好友」项）。
///
/// 数据源对齐 Zephyr-Music social.ts（网易云社交接口族）：
///  - 关注列表  GET /user/follows?uid=&limit=&offset=  → follow[]
///  - 粉丝列表  GET /user/followeds?uid=&limit=&offset= → followeds[]
///  - 私信邀请  POST /send/text {user_ids, msg}（song 之外的纯文本私信）
///
/// 邀请闭环：未开房 → 引导一键创建房间（创建成功自动发私信）；
/// 已开房 → 三路邀请（网易云私信 / 系统分享深链+邀请串 / 复制邀请串）。
/// 好友卡片渲染健壮：头像加载失败/空值兜底占位，昵称空回退「用户{id}」。
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_api.dart' show apiPayload;
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/app_notify.dart';
import '../../../core/widgets/cover_image.dart' show CoverImage;
import '../../../core/widgets/sheet_host.dart' show GlassSheet, showMingSheet;
import '../../auth/presentation/login_sheet.dart' show showLoginSheet;
import '../../auth/providers/auth_providers.dart' show AuthState, authProvider;
import '../../discover/data/netease_providers.dart' show neteaseApiProvider;
import '../providers/listen_room_provider.dart';

/// 好友轻模型（关注/粉丝共通字段）
class FriendUser {
  const FriendUser({
    required this.userId,
    required this.nickname,
    this.avatarUrl = '',
    this.signature = '',
  });

  final int userId;
  final String nickname;
  final String avatarUrl;
  final String signature;

  static FriendUser fromJson(Map<String, Object?> j) => FriendUser(
        userId: (j['userId'] as num?)?.toInt() ?? 0,
        nickname: (j['nickname'] as String?) ?? '',
        avatarUrl: (j['avatarUrl'] as String?) ?? '',
        signature: (j['signature'] as String?) ?? '',
      );
}

/// 好友页
class FriendsPage extends ConsumerStatefulWidget {
  const FriendsPage({super.key});

  @override
  ConsumerState<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends ConsumerState<FriendsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab =
      TabController(length: 2, vsync: this)
        ..addListener(_onTabChanged);
  List<FriendUser> _follows = const <FriendUser>[];
  List<FriendUser> _followeds = const <FriendUser>[];
  bool _loadingFollows = false;
  bool _loadingFolloweds = false;
  String _followsError = '';
  String _followedsError = '';
  int _uid = 0;
  bool _inviting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AuthState auth = ref.read(authProvider);
      if (auth.loggedIn && (auth.profile?.userId ?? 0) > 0) {
        _uid = auth.profile!.userId;
        unawaited(_loadFollows());
      } else {
        unawaited(ref.read(listenRoomProvider.notifier).refreshLogin());
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tab.index != 1) return;
    if (_followeds.isEmpty && _followedsError.isEmpty && !_loadingFolloweds) {
      unawaited(_loadFolloweds());
    }
  }

  Future<void> _loadFollows() async {
    if (_loadingFollows || _uid <= 0) return;
    setState(() {
      _loadingFollows = true;
      _followsError = '';
    });
    try {
      final Map<String, Object?> res = await ref.read(neteaseApiProvider).get(
        '/user/follows',
        <String, String>{
          'uid': '$_uid',
          'limit': '50',
          'offset': '0',
        },
      );
      final Map<String, Object?> data = apiPayload(res);
      final Object? follow = data['follow'];
      if (!mounted) return;
      setState(() {
        _follows = <FriendUser>[
          if (follow is List<Object?>)
            for (final Object? u in follow)
              if (u is Map<String, Object?>) FriendUser.fromJson(u),
        ];
      });
    } catch (e) {
      if (mounted) setState(() => _followsError = '$e');
    } finally {
      if (mounted) setState(() => _loadingFollows = false);
    }
  }

  Future<void> _loadFolloweds() async {
    if (_loadingFolloweds || _uid <= 0) return;
    setState(() {
      _loadingFolloweds = true;
      _followedsError = '';
    });
    try {
      final Map<String, Object?> res = await ref.read(neteaseApiProvider).get(
        '/user/followeds',
        <String, String>{
          'uid': '$_uid',
          'limit': '50',
          'offset': '0',
        },
      );
      final Map<String, Object?> data = apiPayload(res);
      final Object? followeds = data['followeds'];
      if (!mounted) return;
      setState(() {
        _followeds = <FriendUser>[
          if (followeds is List<Object?>)
            for (final Object? u in followeds)
              if (u is Map<String, Object?>) FriendUser.fromJson(u),
        ];
      });
    } catch (e) {
      if (mounted) setState(() => _followedsError = '$e');
    } finally {
      if (mounted) setState(() => _loadingFolloweds = false);
    }
  }

  Future<void> _refresh() async {
    if (_tab.index == 0) {
      await _loadFollows();
    } else {
      await _loadFolloweds();
    }
  }

  // ----------------------------------------------------------- 邀请动作

  /// 邀请好友一起听：未开房 → 一键创建；已开房 → 三路邀请
  Future<void> _invite(FriendUser friend) async {
    if (_inviting) return;
    final ListenRoomState st = ref.read(listenRoomProvider);
    if (st.inRoom) {
      await _showInviteActions(friend);
      return;
    }
    // 未开房：确认后一键创建（创建成功自动发私信，闭环一步到位）
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('邀请 ${friend.nickname.isEmpty ? '好友' : friend.nickname} 一起听'),
        content: const Text('还没有开启一起听房间，创建后即可把邀请私信给TA，'
            'TA点击链接即可加入同步收听。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('创建并邀请'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _inviting = true);
    try {
      final String? err =
          await ref.read(listenRoomProvider.notifier).createRoom();
      if (!mounted) return;
      if (err != null) {
        AppNotify.show(err);
        return;
      }
      AppNotify.success('房间已开启');
      await _showInviteActions(friend, autoPrivate: true);
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  /// 三路邀请动作面板（私信 / 系统分享 / 复制）
  Future<void> _showInviteActions(
    FriendUser friend, {
    bool autoPrivate = false,
  }) {
    return showMingSheet<void>(
      context,
      builder: (BuildContext ctx) => _InviteActionsSheet(
        friend: friend,
        autoPrivate: autoPrivate,
      ),
    );
  }

  // ----------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ListenRoomState room = ref.watch(listenRoomProvider);
    final AuthState auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('好友',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        bottom: TabBar(
          controller: _tab,
          dividerColor: Colors.transparent,
          labelColor: AppConstants.brandColor,
          unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
          indicatorColor: AppConstants.brandColor,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          unselectedLabelStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
          tabs: const <Widget>[
            Tab(text: '关注'),
            Tab(text: '粉丝'),
          ],
        ),
      ),
      body: !auth.loggedIn
          ? _NotLoggedInCard(onLogin: () => showLoginSheet(context))
          : RefreshIndicator(
              color: AppConstants.brandColor,
              onRefresh: _refresh,
              child: TabBarView(
                controller: _tab,
                children: <Widget>[
                  _FriendList(
                    users: _follows,
                    loading: _loadingFollows,
                    error: _followsError,
                    inRoom: room.inRoom,
                    inviting: _inviting,
                    onRetry: () => unawaited(_loadFollows()),
                    onInvite: (FriendUser u) => unawaited(_invite(u)),
                  ),
                  _FriendList(
                    users: _followeds,
                    loading: _loadingFolloweds,
                    error: _followedsError,
                    inRoom: room.inRoom,
                    inviting: _inviting,
                    onRetry: () => unawaited(_loadFolloweds()),
                    onInvite: (FriendUser u) => unawaited(_invite(u)),
                  ),
                ],
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------- 列表

class _FriendList extends StatelessWidget {
  const _FriendList({
    required this.users,
    required this.loading,
    required this.error,
    required this.inRoom,
    required this.inviting,
    required this.onRetry,
    required this.onInvite,
  });

  final List<FriendUser> users;
  final bool loading;
  final String error;
  final bool inRoom;
  final bool inviting;
  final VoidCallback onRetry;
  final void Function(FriendUser) onInvite;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (loading && users.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (error.isNotEmpty && users.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          const SizedBox(height: 60),
          Icon(Icons.cloud_off_rounded,
              size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Center(
            child: Text('加载失败：$error',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 14),
          Center(
            child: OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ),
        ],
      );
    }
    if (users.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          const SizedBox(height: 60),
          Icon(Icons.group_off_rounded,
              size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Center(
            child: Text('这里还没有人',
                style: TextStyle(fontSize: 13)),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      itemCount: users.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) =>
          _FriendCard(user: users[index], inRoom: inRoom, inviting: inviting, onInvite: onInvite),
    );
  }
}

/// 好友卡：头像 + 昵称 + 签名 + 邀请按钮
class _FriendCard extends StatelessWidget {
  const _FriendCard({
    required this.user,
    required this.inRoom,
    required this.inviting,
    required this.onInvite,
  });

  final FriendUser user;
  final bool inRoom;
  final bool inviting;
  final void Function(FriendUser) onInvite;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: inviting ? null : () => onInvite(user),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              ClipOval(
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: user.avatarUrl.isEmpty
                      ? Container(
                          color:
                              theme.colorScheme.primary.withValues(alpha: 0.14),
                          child: Icon(Icons.person_rounded,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant),
                        )
                      : CoverImage(
                          src: user.avatarUrl,
                          size: 84,
                          radius: 21,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      user.nickname.isEmpty
                          ? '用户${user.userId}'
                          : user.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    if (user.signature.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        user.signature,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _InviteBadge(inRoom: inRoom),
            ],
          ),
        ),
      ),
    );
  }
}

/// 邀请按钮徽标（在房=品牌红「邀请」；未开房=灰「开房邀请」）
class _InviteBadge extends StatelessWidget {
  const _InviteBadge({required this.inRoom});

  final bool inRoom;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: inRoom
            ? AppConstants.brandColor
            : AppConstants.brandColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        inRoom ? '邀请' : '开房邀请',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: inRoom ? Colors.white : AppConstants.brandColor,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 动作面板

/// 未登录占位卡
class _NotLoggedInCard extends StatelessWidget {
  const _NotLoggedInCard({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.person_search_rounded,
              size: 44, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Text('登录后查看关注与粉丝，邀请好友一起听',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 14),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: onLogin,
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }
}

/// 三路邀请动作面板：网易云私信 / 系统分享 / 复制邀请串
class _InviteActionsSheet extends ConsumerStatefulWidget {
  const _InviteActionsSheet({
    required this.friend,
    required this.autoPrivate,
  });

  final FriendUser friend;
  final bool autoPrivate;

  @override
  ConsumerState<_InviteActionsSheet> createState() =>
      _InviteActionsSheetState();
}

class _InviteActionsSheetState extends ConsumerState<_InviteActionsSheet> {
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // 「创建并邀请」路径：进面板即自动发私信（用户已确认过意图）
    if (widget.autoPrivate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_sendPrivate());
      });
    }
  }

  Future<void> _sendPrivate() async {
    if (_sending) return;
    setState(() => _sending = true);
    final String? err = await ref
        .read(listenRoomProvider.notifier)
        .sendPrivateInvite(widget.friend.userId,
            widget.friend.nickname.isEmpty ? '好友' : widget.friend.nickname);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      AppNotify.show(err);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ListenRoomState st = ref.watch(listenRoomProvider);
    final String name =
        widget.friend.nickname.isEmpty ? '好友' : widget.friend.nickname;

    return GlassSheet(
      borderRadius: 24,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
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
              const SizedBox(height: 14),
              Text('邀请 $name 一起听',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                st.inRoom
                    ? '房间 ${st.roomId} · ${st.users.length} 人在线'
                    : '尚未开启房间',
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              _ActionRow(
                icon: Icons.send_rounded,
                title: '发网易云私信',
                subtitle: 'TA 在网易云消息里即可看到邀请',
                busy: _sending,
                onTap: _sendPrivate,
              ),
              _ActionRow(
                icon: Icons.ios_share_rounded,
                title: '系统分享邀请',
                subtitle: '分享链接到微信/QQ 等任意应用',
                onTap: () async {
                  await ref
                      .read(listenRoomProvider.notifier)
                      .shareInvite();
                },
              ),
              _ActionRow(
                icon: Icons.copy_rounded,
                title: '复制邀请串',
                subtitle: '好友在「一起听 → 加入」粘贴即可',
                onTap: () async {
                  final String rid = st.roomId;
                  final int inviter = st.inviterId;
                  if (rid.isEmpty) {
                    AppNotify.show('尚未开启房间');
                    return;
                  }
                  await Clipboard.setData(
                      ClipboardData(text: '$rid|$inviter'));
                  AppNotify.success('邀请串已复制');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
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
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppConstants.brandColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(9),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, size: 18, color: AppConstants.brandColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
