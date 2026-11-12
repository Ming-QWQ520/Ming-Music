/// 分享面板（需求第二十八批：按用户提供的参考样式重构 ——
/// 仿网易云「分享至」面板，**最顶部是好友**）。
///
/// 结构（自上而下，与参考图对应）：
///  1. 标题「分享至」；
///  2. **好友行（最顶部）**：联系人（私信会话 + 关注列表合并去重，
///     沿用第二十九批数据源）头像横滚（头像 + 昵称），点击即通过
///     网易云官方私信接口发送资源卡片（/send/song、/send/album、
///     /send/playlist）；行尾「更多」深色圆钮（三点）进好友页；
///  3. 渠道行：系统分享（绿）/ 复制链接（蓝）—— 深色圆形图标 +
///     底部文字，与参考图渠道行同构（App 未接入微信/QQ SDK，
///     实际可用的系统级渠道映射到这两项）；
///  4. 「你还可以分享」：邀请好友一起听（点击进一起听页，
///     仅歌曲分享显示，歌单/专辑分享不展示）。
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/netease_api.dart' show NeteaseApi, apiPayload;
import '../../../core/utils/platform_actions.dart';
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
    isScrollControlled: true,
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

  /// 资源链接（系统分享 / 复制链接统一文案）
  String get _shareText {
    final String link = switch (widget.kind) {
      'song' => 'https://music.163.com/#/song?id=${widget.id}',
      'album' => 'https://music.163.com/#/album?id=${widget.id}',
      _ => 'https://music.163.com/#/playlist?id=${widget.id}',
    };
    return '${widget.name} $link';
  }

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

  /// 点击好友 → 网易云官方私信发送资源卡片
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
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color subText =
        dark ? Colors.white54 : Colors.black.withValues(alpha: 0.5);

    return GlassSheet(
      borderRadius: 24,
      maxHeight: MediaQuery.of(context).size.height * 0.62,
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // ---------- 标题 ----------
              const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 14),
                child: Text('分享至',
                    style: TextStyle(
                        fontSize: 17.5, fontWeight: FontWeight.w700)),
              ),
              // ---------- 好友行（最顶部，参考图第一位） ----------
              _buildFriendsRow(subText),
              const SizedBox(height: 16),
              // ---------- 渠道行 ----------
              Row(
                children: <Widget>[
                  _ChannelIcon(
                    color: const Color(0xFF5AC864),
                    icon: Icons.ios_share_rounded,
                    label: '系统分享',
                    onTap: () async {
                      Navigator.of(context).pop();
                      unawaited(_systemShare());
                    },
                  ),
                  const SizedBox(width: 22),
                  _ChannelIcon(
                    color: const Color(0xFF3D8AF7),
                    icon: Icons.link_rounded,
                    label: '复制链接',
                    onTap: () async {
                      Navigator.of(context).pop();
                      await Clipboard.setData(ClipboardData(text: _shareText));
                      AppNotify.show('已复制分享链接');
                    },
                  ),
                ],
              ),
              if (widget.kind == 'song') ...<Widget>[
                const SizedBox(height: 18),
                Divider(
                    height: 1, color: dark ? Colors.white10 : Colors.black12),
                const SizedBox(height: 12),
                // ---------- 你还可以分享 ----------
                Text('你还可以分享',
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                _ExtraCard(
                  title: '邀请好友一起听',
                  subtitle: '创建房间并转发邀请，实时同步播放进度',
                  icon: Icons.headphones_rounded,
                  gradient: const <Color>[
                    Color(0xFF6C5CE7),
                    Color(0xFF45B5AA),
                  ],
                  onTap: () {
                    Navigator.of(context).pop();
                    context.push('/listen');
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 系统分享（shareText 失败不可用时提示：链接可经复制链接兜底）
  Future<void> _systemShare() async {
    try {
      final bool ok = await PlatformActions.shareText(_shareText);
      if (!ok) AppNotify.show('分享不可用，可复制链接后粘贴发送');
    } catch (_) {
      AppNotify.show('分享不可用，可复制链接后粘贴发送');
    }
  }

  /// 好友行：联系人头像横滚 + 「更多」圆钮（参考图：最顶部是好友）
  Widget _buildFriendsRow(Color subText) {
    if (_loading) {
      return const SizedBox(
        height: 84,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final List<({int userId, String nickname, String avatarUrl})> contacts =
        _contacts;
    if (contacts.isEmpty) {
      return SizedBox(
        height: 84,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _error.isEmpty ? '暂无联系人' : _error,
                style: TextStyle(fontSize: 13, color: subText),
              ),
            ),
            _MoreFriendsButton(onTap: () {
              Navigator.of(context).pop();
              context.push('/friends');
            }),
          ],
        ),
      );
    }
    return SizedBox(
      height: 84,
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: contacts.length,
              separatorBuilder: (BuildContext ctx, int i) =>
                  const SizedBox(width: 18),
              itemBuilder: (BuildContext ctx, int i) {
                final ({int userId, String nickname, String avatarUrl}) c =
                    contacts[i];
                return _FriendAvatar(
                  userId: c.userId,
                  nickname: c.nickname,
                  avatarUrl: c.avatarUrl,
                  busy: _sending.contains(c.userId),
                  onTap: () => unawaited(_send(c.userId, c.nickname)),
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          _MoreFriendsButton(onTap: () {
            Navigator.of(context).pop();
            context.push('/friends');
          }),
        ],
      ),
    );
  }
}

/// 好友头像项（圆头像 + 昵称，参考图样式）
class _FriendAvatar extends StatelessWidget {
  const _FriendAvatar({
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
    required this.onTap,
    this.busy = false,
  });

  final int userId;
  final String nickname;
  final String avatarUrl;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 60,
        child: Column(
          children: <Widget>[
            Stack(
              alignment: Alignment.center,
              children: <Widget>[
                UserAvatar(
                  url: avatarUrl,
                  nickname: nickname,
                  userId: userId,
                  radius: 26,
                ),
                if (busy)
                  const SizedBox(
                    width: 52,
                    height: 52,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              nickname.isEmpty ? '好友' : avatarDisplayName(nickname, userId),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: dark ? Colors.white70 : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「更多」圆钮（深色圆 + 三点，参考图行尾样式）
class _MoreFriendsButton extends StatelessWidget {
  const _MoreFriendsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 60,
        child: Column(
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.06),
              ),
              child: Icon(Icons.more_horiz_rounded,
                  size: 24, color: dark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(height: 6),
            Text('更多',
                style: TextStyle(
                    fontSize: 12,
                    color: dark ? Colors.white70 : Colors.black87)),
          ],
        ),
      ),
    );
  }
}

/// 分享渠道图标（深色圆底 + 彩色图标 + 底部文字，参考图渠道行样式）
class _ChannelIcon extends StatelessWidget {
  const _ChannelIcon({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[color, Color.lerp(color, Colors.black, 0.18)!],
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: color.withValues(alpha: 0.30),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Icon(icon, size: 24, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: dark ? Colors.white70 : Colors.black87)),
          ],
        ),
      ),
    );
  }
}

/// 「你还可以分享」扩展卡（邀请好友一起听）
class _ExtraCard extends StatelessWidget {
  const _ExtraCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          ),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.22),
              ),
              child: Icon(icon, size: 22, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.85))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                size: 22, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}
