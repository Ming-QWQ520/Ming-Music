/// 歌曲评论页（仿网易云 App 评论布局）：
///  - 顶部：返回 + 「评论 (n)」；
///  - 排序 chips：推荐 / 热度 / 时间；
///  - 评论列表：头像 40 圆 + 昵称/IP 属地 + 内容 + 日期，右侧点赞（拇指）；
///  - 无限滚动 + 底部固定发送栏（支持回复）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart' show authProvider, AuthState;
import '../../library/domain/track.dart';
import '../data/comments_repository.dart';
import '../providers/comments_providers.dart';

/// 从播放页进入评论页
Future<void> showCommentsPage(BuildContext context, Track track) {
  final int? songId = track.neteaseId;
  if (songId == null || songId == 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('该歌曲不支持评论（非网易云曲目）')),
    );
    return Future<void>.value();
  }
  return GoRouter.of(context).push<void>(
    '/comments',
    extra: CommentsSubject(id: songId, track: track),
  );
}

class CommentsPage extends StatelessWidget {
  const CommentsPage({
    super.key,
    required this.subject,
  });

  /// 评论主题（歌曲 / 歌单 / 专辑通用）
  final CommentsSubject subject;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, size: 24),
        ),
        title: _Title(subjectKey: subject.key),
      ),
      body: _CommentsBody(subject: subject),
    );
  }
}

// ---------------------------------------------------------------- 标题

class _Title extends ConsumerWidget {
  const _Title({required this.subjectKey});

  final String subjectKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int total =
        ref.watch(commentsProvider(subjectKey)).value?.totalCount ?? 0;
    return Text(
      total > 0 ? '评论 (${_formatCount(total)})' : '评论',
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
    );
  }
}

// ---------------------------------------------------------------- 主体

class _CommentsBody extends ConsumerStatefulWidget {
  const _CommentsBody({required this.subject});

  final CommentsSubject subject;

  @override
  ConsumerState<_CommentsBody> createState() => _CommentsBodyState();
}

class _CommentsBodyState extends ConsumerState<_CommentsBody> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  CommentItem? _replyTo;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void startReply(CommentItem c) {
    setState(() => _replyTo = c);
    _focus.requestFocus();
  }

  Future<void> _send() async {
    final String text = _ctrl.text;
    if (text.trim().isEmpty) return;
    final String? error = await ref
        .read(commentsProvider(widget.subject.key).notifier)
        .send(text, replyTo: _replyTo?.commentId);
    if (!mounted) return;
    if (error == null) {
      _ctrl.clear();
      setState(() => _replyTo = null);
      _focus.unfocus();
    } else {
      _showError(error);
    }
  }

  void _showError(String error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    if (error.contains('登录')) showLoginSheet(context);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<CommentPage?> async =
        ref.watch(commentsProvider(widget.subject.key));
    final Set<int> liked = ref.watch(likedCommentsProvider);
    final int sortType =
        ref.watch(commentsProvider(widget.subject.key).notifier).sortType;

    return Column(
      children: <Widget>[
        if (widget.subject.track != null)
          _SongHeader(track: widget.subject.track!)
        else if (widget.subject.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.subject.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
          child: Row(
            children: <Widget>[
              for (final MapEntry<int, String> e in const <int, String>{
                1: '推荐',
                2: '热度',
                3: '时间',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _SortChip(
                    label: e.value,
                    active: sortType == e.key,
                    onTap: () => ref
                        .read(commentsProvider(widget.subject.key).notifier)
                        .switchSort(e.key),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(child: _buildList(async, liked)),
        _buildInputBar(),
      ],
    );
  }

  // ---------------------------------------------------------------- 列表

  Widget _buildList(AsyncValue<CommentPage?> async, Set<int> liked) {
    if (async.isLoading) {
      return const Center(
        child: CircularProgressIndicator(
            strokeWidth: 2.4, color: AppConstants.brandColor),
      );
    }
    if (async.hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('评论加载失败'),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () =>
                  ref.read(commentsProvider(widget.subject.key).notifier).reload(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final CommentPage? page = async.value;
    final List<CommentItem> comments = page?.comments ?? const <CommentItem>[];
    if (comments.isEmpty) {
      return const Center(
        child: Text('暂无评论，快来抢沙发', style: TextStyle(fontSize: 13.5)),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n.metrics.pixels + 400 >= n.metrics.maxScrollExtent) {
          ref.read(commentsProvider(widget.subject.key).notifier).loadMore();
        }
        return false;
      },
      child: ListView.separated(
        itemCount: comments.length + (page?.hasMore == true ? 1 : 0),
        separatorBuilder: (BuildContext ctx, int i) => Divider(
          height: 1,
          indent: 68,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
        itemBuilder: (BuildContext ctx, int i) {
          if (i >= comments.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final CommentItem c = comments[i];
          // 对齐 Zephyr：自己的评论可删除（t=0）
          final int? myUserId =
              ref.watch(authProvider.select((AuthState s) => s.profile?.userId));
          final bool isMine =
              myUserId != null && myUserId == c.userId;
          return _CommentRow(
            comment: c,
            liked: liked.contains(c.commentId),
            onLike: () async {
              final String? error = await ref
                  .read(commentsProvider(widget.subject.key).notifier)
                  .toggleLike(c);
              if (error != null) _showError(error);
            },
            onReply: () => startReply(c),
            onDelete: isMine
                ? () async {
                    final bool? ok = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext ctx) => AlertDialog(
                        title: const Text('删除评论'),
                        content: const Text('确定删除这条评论吗？'),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    final String? error = await ref
                        .read(commentsProvider(widget.subject.key).notifier)
                        .delete(c);
                    if (error != null) _showError(error);
                  }
                : null,
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- 输入栏

  Widget _buildInputBar() {
    final AuthState auth = ref.watch(authProvider);
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_replyTo != null)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.4),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '回复 @${_replyTo!.nickname}：${_replyTo!.content}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _replyTo = null),
                    child: const Icon(Icons.close_rounded, size: 16),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: auth.loggedIn
                          ? (_replyTo != null
                              ? '回复 @${_replyTo!.nickname}'
                              : '发表你的看法…')
                          : '登录后可发表评论',
                      hintStyle: const TextStyle(fontSize: 13.5),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
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
                const SizedBox(width: 10),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: AppConstants.brandColor,
                  ),
                  onPressed: _send,
                  icon: const Icon(Icons.send_rounded,
                      size: 18, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 头部歌曲卡

class _SongHeader extends StatelessWidget {
  const _SongHeader({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: <Widget>[
          CoverImage(src: track.cover, size: 44, radius: 8),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
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
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 排序 chip

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: active
          ? AppConstants.brandColor
          : (dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.white : null,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 评论行

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.liked,
    required this.onLike,
    required this.onReply,
    this.onDelete,
  });

  final CommentItem comment;
  final bool liked;
  final VoidCallback onLike;
  final VoidCallback onReply;

  /// 自己的评论展示删除入口（null = 非本人无删除）
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onReply,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _avatar(theme),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 昵称 + VIP 徽章（仿网易云）+ IP 属地
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          comment.nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (comment.isVipUser) ...<Widget>[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE7B15C),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            'VIP',
                            style: TextStyle(
                              fontSize: 9,
                              height: 1.2,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF4A3115),
                            ),
                          ),
                        ),
                      ],
                      if (comment.ipLocation.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 6),
                        Text(
                          comment.ipLocation,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    comment.content,
                    style: const TextStyle(fontSize: 14.5, height: 1.45),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Text(
                        _formatDate(comment.time),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.6),
                        ),
                      ),
                      const Spacer(),
                      // 点赞（仿网易云：图标 + 数量，赞过变红）
                      InkWell(
                        onTap: onLike,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                liked
                                    ? Icons.thumb_up_alt_rounded
                                    : Icons.thumb_up_alt_outlined,
                                size: 14,
                                color: liked
                                    ? AppConstants.brandColor
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              if (comment.likedCount > 0) ...<Widget>[
                                const SizedBox(width: 4),
                                Text(
                                  _formatCount(comment.likedCount),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: liked
                                        ? AppConstants.brandColor
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        onTap: onReply,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Icon(
                            Icons.mode_comment_outlined,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (onDelete != null) ...<Widget>[
                        const SizedBox(width: 10),
                        InkWell(
                          onTap: onDelete,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Icon(
                              Icons.delete_outline_rounded,
                              size: 15,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(ThemeData theme) {
    if (comment.avatarUrl.isEmpty) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child:
            const Icon(Icons.person_rounded, size: 22, color: Colors.white54),
      );
    }
    return CoverImage(src: comment.avatarUrl, size: 40, radius: 20);
  }
}

// ---------------------------------------------------------------- utils

String _formatCount(int n) {
  if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
  return '$n';
}

String _formatDate(int ms) {
  if (ms <= 0) return '';
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}
