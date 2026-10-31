/// 统一用户头像组件（第二十六批：一起听显示双方头像 + 私信列表/气泡）。
///
/// 兜底链（保证任何数据形态都正常渲染，不出现空白框）：
///  1. url 非空 → 网络图（fetchBytes：浏览器 UA + 内存缓存 + 多级重试）；
///  2. 加载失败 → 昵称首字彩色圆；
///  3. url 为空 → 昵称首字彩色圆（匿名号昵称为空 → 「用户{id}」；
///     颜色由昵称/id 哈希从调色板取，同人同色）。
library;

import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';

import 'cover_image.dart' show CoverSize, fetchBytes;

/// 兜底色板（首字彩色圆底色，白字可读）
const List<Color> _kAvatarPalette = <Color>[
  Color(0xFFE57373),
  Color(0xFFF48FB1),
  Color(0xFFBA68C8),
  Color(0xFF9575CD),
  Color(0xFF7986CB),
  Color(0xFF64B5F6),
  Color(0xFF4FC3F7),
  Color(0xFF4DD0E1),
  Color(0xFF4DB6AC),
  Color(0xFF81C784),
  Color(0xFFAED581),
  Color(0xFFFFB74D),
  Color(0xFFFF8A65),
];

/// 由种子（昵称/用户id）稳定取兜底色：同人同色
Color avatarFallbackColor(String seed) {
  if (seed.isEmpty) return _kAvatarPalette.first;
  int h = 0;
  for (final int c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _kAvatarPalette[h % _kAvatarPalette.length];
}

/// 显示名兜底：昵称空 → 「用户{id}」（匿名号 roomUsers 的 nickname 为 null）
String avatarDisplayName(String nickname, int userId) {
  if (nickname.trim().isNotEmpty) return nickname.trim();
  return '用户$userId';
}

/// 首字彩色圆兜底（单独导出：成员条/会话行等需要内联兜底时复用）
class AvatarFallback extends StatelessWidget {
  const AvatarFallback({
    super.key,
    required this.nickname,
    this.userId = 0,
    this.radius = 18,
    this.fontSize,
  });

  final String nickname;
  final int userId;
  final double radius;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final String name = avatarDisplayName(nickname, userId);
    final Color bg = avatarFallbackColor(
        nickname.trim().isNotEmpty ? nickname.trim() : '$userId');
    // 取第一个「可见字形」：跳过空白与符号
    String ch = '';
    for (final String c in name.characters) {
      if (c.trim().isNotEmpty) {
        ch = c;
        break;
      }
    }
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      color: bg,
      child: Text(
        ch.isEmpty ? '友' : ch,
        maxLines: 1,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.96),
          fontWeight: FontWeight.w700,
          fontSize: fontSize ?? radius * 0.72,
        ),
      ),
    );
  }
}

/// 头像堆叠（一起听「双方头像」样式：成员头像重叠排列，最多展示
/// [max] 个，超出显示 +N）。
///
/// [members] 用记录类型解耦 core 与 listen 层：
/// `(url: avatarUrl, nickname: nickname, userId: userId)`。
class AvatarStack extends StatelessWidget {
  const AvatarStack({
    super.key,
    required this.members,
    this.radius = 10,
    this.max = 3,
    this.borderPadding = 1.6,
  });

  final List<({String url, String nickname, int userId})> members;
  final double radius;

  /// 最多展示的头像个数
  final int max;

  /// 叠加白边（负 margin 前的视觉分隔）
  final double borderPadding;

  @override
  Widget build(BuildContext context) {
    final int shown = members.length > max ? max : members.length;
    final int overflow = members.length - shown;
    final double step = radius * 2 - borderPadding * 2;
    return SizedBox(
      width: step * (shown + (overflow > 0 ? 1 : 0)) + borderPadding * 2,
      height: radius * 2 + borderPadding * 2,
      child: Stack(
        children: <Widget>[
          for (int i = 0; i < shown; i++)
            Positioned(
              left: step * i,
              child: Container(
                padding: EdgeInsets.all(borderPadding),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: UserAvatar(
                  url: members[i].url,
                  nickname: members[i].nickname,
                  userId: members[i].userId,
                  radius: radius - borderPadding,
                ),
              ),
            ),
          if (overflow > 0)
            Positioned(
              left: step * shown,
              child: Container(
                width: (radius - borderPadding) * 2,
                height: (radius - borderPadding) * 2,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '+$overflow',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: radius * 0.66,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class UserAvatar extends StatefulWidget {
  const UserAvatar({
    super.key,
    required this.url,
    required this.nickname,
    this.userId = 0,
    this.radius = 18,
  });

  final String url;
  final String nickname;
  final int userId;
  final double radius;

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  Uint8List? _bytes;
  bool _failed = false;
  String? _loadedUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final String url = widget.url.trim();
    if (url.isEmpty || !url.startsWith('http')) return;
    final Uint8List? bytes = await fetchBytes(url, CoverSize.small).timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
    if (!mounted || url != widget.url.trim()) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
      _loadedUrl = url;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _bytes;
    if (bytes != null && _loadedUrl == widget.url.trim()) {
      return ClipOval(
        child: Image.memory(
          bytes,
          width: widget.radius * 2,
          height: widget.radius * 2,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => AvatarFallback(
            nickname: widget.nickname,
            userId: widget.userId,
            radius: widget.radius,
          ),
        ),
      );
    }
    if (_failed) {
      return AvatarFallback(
        nickname: widget.nickname,
        userId: widget.userId,
        radius: widget.radius,
      );
    }
    // 加载中：先渲染首字兜底（真图到达后无缝替换，不留空白框）
    return AvatarFallback(
      nickname: widget.nickname,
      userId: widget.userId,
      radius: widget.radius,
    );
  }
}
