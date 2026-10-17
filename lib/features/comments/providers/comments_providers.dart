/// 评论页状态：分页加载 / 排序切换 / 乐观点赞 / 发送回复。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_api.dart';
import '../../../core/storage/prefs_keys.dart';
import '../../auth/providers/auth_providers.dart' show authProvider, AuthState;
import '../../discover/data/netease_providers.dart' show neteaseApiProvider;
import '../../settings/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import '../data/comments_repository.dart';

final Provider<CommentsRepository> commentsRepositoryProvider =
    Provider<CommentsRepository>(
  (Ref ref) => CommentsRepository(ref.watch(neteaseApiProvider)),
);

/// 歌曲评论总数（轻量请求 pageSize=1）：播放页信息区仿网易云展示「20万+」
final FutureProviderFamily<int, int> songCommentCountProvider =
    FutureProvider.family<int, int>((Ref ref, int songId) async {
  try {
    final CommentPage page = await ref
        .read(commentsRepositoryProvider)
        .fetchComments(songId, pageSize: 1);
    return page.totalCount;
  } catch (_) {
    return 0;
  }
});

/// 已点赞评论集合（本地持久化：服务端未提供「我赞过的评论」查询）
final NotifierProvider<LikedCommentsNotifier, Set<int>> likedCommentsProvider =
    NotifierProvider<LikedCommentsNotifier, Set<int>>(
        LikedCommentsNotifier.new);

class LikedCommentsNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() {
    final String? raw =
        ref.watch(sharedPreferencesProvider).getString(PrefsKeys.likedComments);
    if (raw == null || raw.isEmpty) return const <int>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List<Object?>) {
        return decoded.whereType<num>().map((num e) => e.toInt()).toSet();
      }
    } catch (_) {}
    return const <int>{};
  }

  void _commit(Set<int> next) {
    state = next;
    ref
        .read(sharedPreferencesProvider)
        .setString(PrefsKeys.likedComments, jsonEncode(next.toList()));
  }

  bool isLiked(int cid) => state.contains(cid);

  void setLiked(int cid, bool liked) {
    final Set<int> next = Set<int>.of(state);
    if (liked) {
      next.add(cid);
    } else {
      next.remove(cid);
    }
    _commit(next);
  }
}

/// 单首歌曲的评论页状态（按 songId family 隔离）
class CommentsController extends FamilyAsyncNotifier<CommentPage?, int> {
  int _sortType = 1;
  int _pageNo = 1;
  int _cursor = 0;

  int get sortType => _sortType;

  @override
  Future<CommentPage?> build(int songId) async {
    _sortType = 1;
    _pageNo = 1;
    _cursor = 0;
    return _fetch(reset: true);
  }

  Future<CommentPage?> _fetch({required bool reset}) async {
    if (reset) {
      _pageNo = 1;
      _cursor = 0;
    }
    try {
      final CommentPage page =
          await ref.read(commentsRepositoryProvider).fetchComments(
                arg,
                sortType: _sortType,
                pageNo: _pageNo,
                pageSize: 20,
                cursor: _cursor == 0 ? null : _cursor,
              );
      if (reset) {
        _cursor = page.cursor ?? 0;
        _pageNo = 2;
        return page;
      }
      final CommentPage? current = state.value;
      _cursor = page.cursor ?? 0;
      _pageNo += 1;
      if (current == null) return page;
      return CommentPage(
        comments: <CommentItem>[...current.comments, ...page.comments],
        totalCount: page.totalCount,
        hasMore: page.hasMore,
        cursor: _cursor,
      );
    } on ApiException {
      if (reset) rethrow;
      // 追加失败：保持现有数据
      return state.value;
    }
  }

  Future<void> switchSort(int sortType) async {
    if (_sortType == sortType) return;
    _sortType = sortType;
    state = const AsyncValue<CommentPage?>.loading();
    state = await AsyncValue.guard<CommentPage?>(() => _fetch(reset: true));
  }

  Future<void> loadMore() async {
    final CommentPage? current = state.value;
    if (current == null || !current.hasMore) return;
    if (state.isLoading) return;
    state = await AsyncValue.guard<CommentPage?>(() => _fetch(reset: false));
  }

  Future<void> reload() async {
    state = const AsyncValue<CommentPage?>.loading();
    state = await AsyncValue.guard<CommentPage?>(() => _fetch(reset: true));
  }

  /// 发送评论（t=1）/ 回复（t=2）。返回错误文案（null 成功）
  Future<String?> send(String content, {int? replyTo}) async {
    if (content.trim().isEmpty) return '评论内容不能为空';
    final (int code, String msg) =
        await ref.read(commentsRepositoryProvider).action(
              t: replyTo == null ? 1 : 2,
              songId: arg,
              content: content.trim(),
              commentId: replyTo,
            );
    if (code == 200) {
      await reload();
      return null;
    }
    return _errorMessage(code, msg);
  }

  /// 点赞 / 取消点赞（乐观更新 + 失败回滚）。返回错误文案（null 成功）
  Future<String?> toggleLike(CommentItem comment) async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return '登录后才能点赞';

    final LikedCommentsNotifier liked =
        ref.read(likedCommentsProvider.notifier);
    final bool wasLiked = liked.isLiked(comment.commentId);
    liked.setLiked(comment.commentId, !wasLiked);

    // 本地同步调整赞数（重新构建带新数量的 CommentItem）
    void adjust(int delta) {
      final CommentPage? page = state.value;
      if (page == null) return;
      final List<CommentItem> next = page.comments
          .map((CommentItem c) => c.commentId == comment.commentId
              ? CommentItem(
                  commentId: c.commentId,
                  content: c.content,
                  time: c.time,
                  likedCount:
                      c.likedCount + delta < 0 ? 0 : c.likedCount + delta,
                  userId: c.userId,
                  nickname: c.nickname,
                  avatarUrl: c.avatarUrl,
                  ipLocation: c.ipLocation,
                  isVipUser: c.isVipUser,
                )
              : c)
          .toList(growable: false);
      state = AsyncValue<CommentPage?>.data(CommentPage(
        comments: next,
        totalCount: page.totalCount,
        hasMore: page.hasMore,
        cursor: page.cursor,
      ));
    }

    adjust(wasLiked ? -1 : 1);
    try {
      final (int code, String msg) =
          await ref.read(commentsRepositoryProvider).like(
                songId: arg,
                commentId: comment.commentId,
                like: !wasLiked,
              );
      if (code == 200) return null;
      adjust(wasLiked ? 1 : -1);
      liked.setLiked(comment.commentId, wasLiked);
      return _errorMessage(code, msg);
    } catch (_) {
      adjust(wasLiked ? 1 : -1);
      liked.setLiked(comment.commentId, wasLiked);
      return '网络异常，请稍后重试';
    }
  }

  String _errorMessage(int code, String msg) {
    if (msg.isNotEmpty) return msg;
    return switch (code) {
      301 || 302 => '需要登录后操作',
      250 => '风控限制，请在网易云音乐 App 中操作',
      _ => '操作失败 (code: $code)',
    };
  }
}

final AsyncNotifierProviderFamily<CommentsController, CommentPage?, int>
    commentsProvider =
    AsyncNotifierProviderFamily<CommentsController, CommentPage?, int>(
        CommentsController.new);
