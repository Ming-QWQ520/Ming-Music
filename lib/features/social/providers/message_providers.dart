/// 私信状态（第二十六批：私信功能，借鉴 Zephyr MessageView 的数据流）。
///
///  - [conversationsProvider]：会话列表（拉取 + 下拉刷新 + 未读总数派生）；
///  - 我的页「私信」磁贴副标题读未读总数（keepAlive，应用启动即拉一次）。
library;

import 'dart:async' show unawaited;

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
  });

  final List<Conversation> items;
  final bool loading;
  final String error;
  final bool more;

  /// 未读总数（磁贴角标）
  int get unreadTotal =>
      items.fold<int>(0, (int acc, Conversation c) => acc + c.newMsgCount);

  ConversationsState copyWith({
    List<Conversation>? items,
    bool? loading,
    String? error,
    bool? more,
  }) {
    return ConversationsState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: error ?? this.error,
      more: more ?? this.more,
    );
  }
}

class ConversationsNotifier extends Notifier<ConversationsState> {
  @override
  ConversationsState build() {
    unawaited(load());
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
