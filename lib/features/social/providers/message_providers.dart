/// 私信状态（第二十六批：私信功能，借鉴 Zephyr MessageView 的数据流）。
///
///  - [conversationsProvider]：会话列表（拉取 + 下拉刷新 + 未读总数派生）；
///  - 我的页「私信」磁贴副标题读未读总数（keepAlive，应用启动即拉一次）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../discover/data/netease_providers.dart' show neteaseApiProvider;
import '../data/message_repository.dart';

final Provider<MessageRepository> messageRepositoryProvider =
    Provider<MessageRepository>(
        (Ref ref) => MessageRepository(ref.read(neteaseApiProvider)));

/// 会话列表状态
class ConversationsState {
  const ConversationsState({
    this.items = const <Conversation>[],
    this.loading = false,
    this.error = '',
    this.more = false,
    this.clearedUserIds = const <int>{},
  });

  final List<Conversation> items;
  final bool loading;
  final String error;
  final bool more;

  /// 本会话周期内已读过的联系人（需求第二十九批：点开联系人页即消除
  /// 红点；网易没有已读回执接口，服务端可能仍报未读 —— 加载时按这里
  /// 遮罩归零，会话周期内不再复现红点）
  final Set<int> clearedUserIds;

  /// 未读总数（磁贴角标）
  int get unreadTotal =>
      items.fold<int>(0, (int acc, Conversation c) => acc + c.newMsgCount);

  ConversationsState copyWith({
    List<Conversation>? items,
    bool? loading,
    String? error,
    bool? more,
    Set<int>? clearedUserIds,
  }) {
    return ConversationsState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: error ?? this.error,
      more: more ?? this.more,
      clearedUserIds: clearedUserIds ?? this.clearedUserIds,
    );
  }

  /// 按已读遮罩归零后的会话列表（加载/点开/一键已读统一出口）
  List<Conversation> get maskedItems => <Conversation>[
        for (final Conversation c in items)
          if (clearedUserIds.contains(c.userId) && c.newMsgCount != 0)
            Conversation(
              userId: c.userId,
              nickname: c.nickname,
              avatarUrl: c.avatarUrl,
              lastMsg: c.lastMsg,
              lastMsgTime: c.lastMsgTime,
              newMsgCount: 0,
            )
          else
            c,
      ];
}

class ConversationsNotifier extends Notifier<ConversationsState> {
  @override
  ConversationsState build() {
    // Future.microtask 延迟到 build 返回后再加载。修复：build 内同步调
    // load() 会在 provider 初始化完成前读 state，riverpod 抛
    // 「Tried to read the state of an uninitialized provider」
    //（用户日志 21:47:57 / 21:56:27 两次实录）。
    Future.microtask(() => load());
    return const ConversationsState();
  }

  Future<void> load() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, error: '');
    try {
      final List<Conversation> list =
          await ref.read(messageRepositoryProvider).conversations();
      state = state.copyWith(
        items: list,
        loading: false,
        more: list.length >= 30,
        error: '',
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  /// 需求（第二十九批）：点击联系人进入聊天后消除红点 —— 本地立即置零
  /// 并记入已读遮罩（后续 load/loadMore 拉回的旧未读数不再复现）。
  void clearUnread(int userId) {
    if (userId <= 0) return;
    state = state.copyWith(
      clearedUserIds: <int>{...state.clearedUserIds, userId},
    );
  }

  /// 需求（第二十九批）：私信页「一键已读」—— 全部会话红点清零。
  void markAllRead() {
    state = state.copyWith(
      clearedUserIds: <int>{
        ...state.clearedUserIds,
        for (final Conversation c in state.items) c.userId,
      },
    );
  }

  Future<void> loadMore() async {
    if (state.loading || !state.more) return;
    state = state.copyWith(loading: true);
    try {
      final List<Conversation> list = await ref
          .read(messageRepositoryProvider)
          .conversations(offset: state.items.length);
      state = state.copyWith(
        items: <Conversation>[...state.items, ...list],
        loading: false,
        more: list.length >= 30,
      );
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }
}

final NotifierProvider<ConversationsNotifier, ConversationsState>
    conversationsProvider =
    NotifierProvider<ConversationsNotifier, ConversationsState>(
        ConversationsNotifier.new);
