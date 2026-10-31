/// 私信分享给好友（需求第二十九批：阅读文档
/// https://musicapi.mingqwq.top/docs/#/?id=发送私信带歌曲 / 带专辑 / 带歌单
/// 后接入的发送侧 —— POST /send/song、/send/album、/send/playlist）。
///
/// 底部面板 = 联系人选择器（私信会话 + 关注列表合并去重），选中即发送；
/// 玩家更多面板（歌曲）、歌单详情页（歌单）、专辑页（专辑）三处入口复用。
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_api.dart' show NeteaseApi, apiPayload;
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/app_notify.dart';
import '../../../core/widgets/sheet_host.dart' show GlassSheet, showMingSheet;
import '../../../core/widgets/user_avatar.dart';
import '../../discover/data/netease_providers.dart' show neteaseApiProvider;
import '../data/message_repository.dart' show Conversation, MessageRepository;
import '../providers/message_providers.dart' show messageRepositoryProvider;

/// 弹出「私信分享给好友」面板。
///
/// [kind] = 'song' | 'album' | 'playlist'；[id] 对应资源 id；[name] 用于
/// 默认留言与面板标题。
Future<void> showShareToFriendSheet(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required int id,
  required String name,
}) async {
  if (id <= 0) {
    AppNotify.show('分享失败：没有可用的资源 id');
    return;
  }
  await showMingSheet<void>(
    context,
    builder: (BuildContext ctx) => _ShareToFriendSheet(
      kind: kind,
      id: id,
      name: name,
      // 面板内部也要发请求 → 把 repository 传进来（调用方 ref 可读）
      repository: ref.read(messageRepositoryProvider),
      api: ref.read(neteaseApiProvider),
    ),
  );
}

class _ShareToFriendSheet extends StatefulWidget {
  const _ShareToFriendSheet({
    required this.kind,
    required this.id,
    required this.name,
    required this.repository,
    required this.api,
  });

  final String kind;
  final int id;
  final String name;
  final MessageRepository repository;
  final NeteaseApi api;

  @override
  State<_ShareToFriendSheet> createState() => _ShareToFriendSheetState();
}

class _ShareToFriendSheetState extends State<_ShareToFriendSheet> {
  List<({int userId, String nickname, String avatarUrl})> _contacts =
      const <({int userId, String nickname, String avatarUrl})>[];
  String _error = '';
  bool _loading = true;
  final Set<int> _sending = <int>{};

  String get _kindLabel => switch (widget.kind) {
        'song' => '歌曲',
        'album' => '专辑',
        _ => '歌单',
      };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 联系人 = 私信会话 + 我的关注（合并去重，会话在前）
  Future<void> _load() async {
    final List<({int userId, String nickname, String avatarUrl})> merged =
        <({int userId, String nickname, String avatarUrl})>[];
    final Set<int> seen = <int>{};
    try {
      final List<Conversation> conversations =
          await widget.repository.conversations();
      for (final Conversation c in conversations) {
        if (seen.add(c.userId)) {
          merged.add((
            userId: c.userId,
            nickname: c.nickname,
            avatarUrl: c.avatarUrl,
          ));
        }
      }
    } catch (_) {
      // 会话失败不阻塞：还有关注列表
    }
    try {
      // 我的关注（/user/follows 需要自己的 uid，/user/account 一步到位）
      final Map<String, Object?> acc =
          await widget.api.get('/user/account', const <String, String>{});
      final Map<String, Object?>? profile =
          apiPayload(acc)['profile'] as Map<String, Object?>?;
      final int uid = (profile?['userId'] as num?)?.toInt() ?? 0;
      if (uid > 0) {
        final Map<String, Object?> res = await widget.api.get(
          '/user/follows',
          <String, String>{'uid': '$uid', 'limit': '50', 'offset': '0'},
        );
        final Object? follow = apiPayload(res)['follow'];
        if (follow is List<Object?>) {
          for (final Object? u in follow) {
            if (u is! Map<String, Object?>) continue;
            final Map<String, Object?> pf =
                (u['profile'] as Map<String, Object?>?) ?? u;
            final int fuid = (pf['userId'] as num?)?.toInt() ?? 0;
            final String nn = (pf['nickname'] as String?) ?? '';
            final String av = (pf['avatarUrl'] as String?) ?? '';
            if (fuid > 0 && seen.add(fuid)) {
              merged.add((userId: fuid, nickname: nn, avatarUrl: av));
            }
          }
        }
      }
    } catch (_) {
      // 关注列表失败不阻塞
    }
    if (!mounted) return;
    setState(() {
      _contacts = merged;
      _loading = false;
      _error = merged.isEmpty ? '暂无联系人（先关注好友或有过私信）' : '';
    });
  }

  Future<void> _send(int userId, String nickname) async {
    if (_sending.contains(userId)) return;
    setState(() => _sending.add(userId));
    final String display = nickname.isEmpty ? '好友' : nickname;
    final String msg = '给你分享一个$_kindLabel：${widget.name}';
    final Future<String?> future = switch (widget.kind) {
      'song' => widget.repository.sendSong(userId, widget.id, msg),
      'album' => widget.repository.sendAlbum(userId, widget.id, msg),
      _ => widget.repository.sendPlaylist(userId, widget.id, msg),
    };
    final String? err = await future;
    if (!mounted) return;
    setState(() => _sending.remove(userId));
    if (err != null) {
      AppNotify.show('分享给 $display 失败：$err');
      return;
    }
    AppNotify.success('已把$_kindLabel私信给 $display');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
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
              Text('私信分享$_kindLabel',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4)),
                  ),
                )
              else if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text(_error,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _contacts.length,
                    itemBuilder: (BuildContext ctx, int i) {
                      final ({
                        int userId,
                        String nickname,
                        String avatarUrl
                      }) c = _contacts[i];
                      final bool sending = _sending.contains(c.userId);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: sending
                                ? null
                                : () => unawaited(_send(c.userId, c.nickname)),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 7),
                              child: Row(
                                children: <Widget>[
                                  UserAvatar(
                                    url: c.avatarUrl,
                                    nickname: c.nickname,
                                    userId: c.userId,
                                    radius: 19,
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Text(
                                      avatarDisplayName(c.nickname, c.userId),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  sending
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2.2))
                                      : Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: AppConstants.brandColor
                                                .withValues(alpha: 0.14),
                                            borderRadius:
                                                BorderRadius.circular(14),
                                          ),
                                          child: const Text('发送',
                                              style: TextStyle(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w700,
                                                  color:
                                                      AppConstants.brandColor)),
                                        ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
