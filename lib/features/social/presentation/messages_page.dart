/// 私信页（第二十六批需求：添加私信，功能完全借鉴 Zephyr-Music
/// MessageView —— 数据流同源：/msg/private 会话列表，点击进聊天页）。
///
/// 移动端布局：全屏会话列表（头像/昵称/最后消息/时间/未读徽标），
/// 点击进入聊天页；含一起听邀请的消息在聊天页渲染成点击即加入的卡片。
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/presentation/login_sheet.dart' show showLoginSheet;
import '../../auth/providers/auth_providers.dart' show authProvider;
import '../data/message_repository.dart' show Conversation;
import '../providers/message_providers.dart';

class MessagesPage extends ConsumerStatefulWidget {
  const MessagesPage({super.key});

  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ConversationsState st = ref.watch(conversationsProvider);
    final bool loggedIn = ref.watch(authProvider).loggedIn;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('私信',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        actions: <Widget>[
          // 需求（第二十九批）：一键已读 —— 有未读时展示，点击全部会话
          // 红点清零（本地遮罩，服务端拉回的旧未读不再复现）。
          if (loggedIn && st.unreadTotal > 0)
            TextButton.icon(
              onPressed: () =>
                  ref.read(conversationsProvider.notifier).markAllRead(),
              icon: const Icon(Icons.done_all_rounded, size: 17),
              label: const Text('一键已读',
                  style:
                      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(
                foregroundColor: AppConstants.brandColor,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: () =>
                unawaited(ref.read(conversationsProvider.notifier).load()),
            icon: const Icon(Icons.refresh_rounded, size: 22),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: !loggedIn
          ? _NotLoggedIn(onLogin: () => showLoginSheet(context))
          : RefreshIndicator(
              color: AppConstants.brandColor,
              onRefresh: () => ref.read(conversationsProvider.notifier).load(),
              child: NotificationListener<ScrollNotification>(
                onNotification: (ScrollNotification n) {
                  if (n.metrics.pixels > n.metrics.maxScrollExtent - 240) {
                    unawaited(
                        ref.read(conversationsProvider.notifier).loadMore());
                  }
                  return false;
                },
                child: _buildList(theme, st),
              ),
            ),
    );
  }

  Widget _buildList(ThemeData theme, ConversationsState st) {
    if (st.loading && st.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const <Widget>[
          SizedBox(height: 120),
          Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          ),
        ],
      );
    }
    if (st.error.isNotEmpty && st.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          const SizedBox(height: 60),
          Icon(Icons.cloud_off_rounded,
              size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Center(
            child: Text('加载失败：${st.error}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 14),
          Center(
            child: OutlinedButton(
              onPressed: () =>
                  unawaited(ref.read(conversationsProvider.notifier).load()),
              child: const Text('重试'),
            ),
          ),
        ],
      );
    }
    if (st.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: const <Widget>[
          SizedBox(height: 60),
          Icon(Icons.mail_outline_rounded, size: 44, color: Colors.grey),
          SizedBox(height: 12),
          Center(
            child: Text('暂无私信，去好友页邀请好友一起听吧', style: TextStyle(fontSize: 13)),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      itemCount: st.maskedItems.length + (st.more ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (BuildContext context, int index) {
        if (index >= st.maskedItems.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
          );
        }
        return _ConversationTile(c: st.maskedItems[index]);
      },
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.c});

  final Conversation c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          // 需求（第二十九批）：点开联系人页面后消除红点 —— 本地遮罩
          // 立即置零（磁贴角标同步减少），再进聊天页。
          ref.read(conversationsProvider.notifier).clearUnread(c.userId);
          context.push('/messages/${c.userId}'
              '?name=${Uri.encodeComponent(avatarDisplayName(c.nickname, c.userId))}'
              '&avatar=${Uri.encodeComponent(c.avatarUrl)}');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          child: Row(
            children: <Widget>[
              UserAvatar(
                url: c.avatarUrl,
                nickname: c.nickname,
                userId: c.userId,
                radius: 23,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            avatarDisplayName(c.nickname, c.userId),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          _formatTime(c.lastMsgTime),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      c.lastMsg.isEmpty ? '（无文本内容）' : c.lastMsg,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (c.newMsgCount > 0) ...<Widget>[
                const SizedBox(width: 8),
                Container(
                  constraints: const BoxConstraints(minWidth: 17),
                  height: 17,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppConstants.brandColor,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    c.newMsgCount > 99 ? '99+' : '${c.newMsgCount}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _formatTime(int ms) {
  if (ms <= 0) return '';
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  final DateTime now = DateTime.now();
  final bool today =
      d.year == now.year && d.month == now.month && d.day == now.day;
  final String hh = d.hour.toString().padLeft(2, '0');
  final String mm = d.minute.toString().padLeft(2, '0');
  if (today) return '$hh:$mm';
  return '${d.month}/${d.day} $hh:$mm';
}

class _NotLoggedIn extends StatelessWidget {
  const _NotLoggedIn({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.mail_outline_rounded,
              size: 44, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Text('登录后查看与好友的私信', style: TextStyle(fontSize: 13)),
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
