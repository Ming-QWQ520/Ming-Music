/// 私信数据层（第二十六批需求：添加私信，功能完全借鉴 Zephyr-Music
/// `src/api/netease/social.ts` 的接口用法与消息解析）。
///
/// 接口族（与 Zephyr 同源）：
///  - 会话列表  GET  /msg/private?limit=&offset=
///      → msgs[]：每项含 fromUser/toUser/lastMsg/lastMsgTime/newMsgCount；
///      注意：必须用此接口取「有私信记录的联系人」，
///      不要用 /msg/recentcontact（那是关注列表，不一定有私信）；
///  - 聊天记录  GET  /msg/private/history?uid=&limit=&before=
///      → msgs[]：fromUser/toUser/msg/time/id，**返回最新在前**（需反转）；
///      msg 字段是 JSON 字符串，需 parseMsgField 提取实际文本；
///  - 发送私信  POST /send/text {user_ids, msg}（不能发给自己）。
///
/// 一起听邀请闭环：消息文本里含邀请信息（深链/邀请串）时，
/// [ChatMessage.invite] 非空 —— 聊天页渲染成可点击的「加入一起听」卡片。
library;

import 'dart:convert' show jsonDecode;

import '../../../core/api/netease_api.dart';
import '../../listen/providers/listen_room_provider.dart'
    show ListenInvite, parseListenInvite;

/// 会话（会话列表一行）
class Conversation {
  const Conversation({
    required this.userId,
    required this.nickname,
    this.avatarUrl = '',
    this.lastMsg = '',
    this.lastMsgTime = 0,
    this.newMsgCount = 0,
  });

  final int userId;
  final String nickname;
  final String avatarUrl;

  /// 最后一条消息预览（已提取纯文本）
  final String lastMsg;

  /// 最后消息时间（毫秒时间戳）
  final int lastMsgTime;

  /// 未读数
  final int newMsgCount;

  static Conversation fromJson(Map<String, Object?> j, int myId) {
    final Map<String, Object?>? from = j['fromUser'] as Map<String, Object?>?;
    final Map<String, Object?>? to = j['toUser'] as Map<String, Object?>?;
    // 对方 = fromUser 不是自己就是 fromUser，否则是 toUser（Zephyr 同款）
    final Map<String, Object?>? other =
        ((from?['userId'] as num?)?.toInt() ?? 0) != myId ? from : to;
    return Conversation(
      userId: (other?['userId'] as num?)?.toInt() ?? 0,
      nickname: (other?['nickname'] as String?) ?? '',
      avatarUrl: (other?['avatarUrl'] as String?) ?? '',
      lastMsg: parseMsgField(j['lastMsg']),
      lastMsgTime: (j['lastMsgTime'] as num?)?.toInt() ?? 0,
      newMsgCount: (j['newMsgCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 聊天消息（气泡）
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.content,
    required this.time,
    required this.isSelf,
    this.invite,
    this.share,
  });

  final String id;
  final int fromUserId;
  final int toUserId;
  final String content;
  final int time;
  final bool isSelf;

  /// 非空 = 消息含一起听邀请（聊天页渲染成点击即加入的卡片）
  final ListenInvite? invite;

  /// 非空 = 消息带歌曲/专辑/歌单分享（需求第二十九批：send/song、
  /// send/album、send/playlist 的接收侧 —— 聊天页渲染成可点卡片）
  final MsgShare? share;

  static ChatMessage fromJson(Map<String, Object?> j, int myId) {
    final Map<String, Object?>? from = j['fromUser'] as Map<String, Object?>?;
    final Map<String, Object?>? to = j['toUser'] as Map<String, Object?>?;
    final int fromId = (from?['userId'] as num?)?.toInt() ?? 0;
    final Object? rawMsg = j['msg'];
    final String content = parseMsgField(rawMsg);
    return ChatMessage(
      id: '${j['id'] ?? j['time'] ?? content.hashCode}',
      fromUserId: fromId,
      toUserId: (to?['userId'] as num?)?.toInt() ?? 0,
      content: content,
      time: (j['time'] as num?)?.toInt() ?? 0,
      isSelf: fromId == myId,
      invite: parseListenInvite(content),
      share: parseMsgShare(rawMsg),
    );
  }
}

/// 私信分享卡（带歌曲/专辑/歌单的私信）。网易 msg 字段是 JSON 串，
/// 不同分享类型键名不一（id/songId/albumId/playlistId、嵌套
/// song/album/playlist 对象、type 枚举），宽容深度解析。
class MsgShare {
  const MsgShare({
    required this.kind,
    required this.id,
    this.name = '',
    this.hint = '',
  });

  /// 'song' | 'album' | 'playlist'
  final String kind;
  final int id;
  final String name;
  final String hint;

  static MsgShare? fromJson(Map<String, Object?> j) {
    // 深度搜指定键（任意嵌套层）
    Object? deep(List<String> keys) {
      Object? walk(Object? node) {
        if (node is Map<String, Object?>) {
          for (final String k in keys) {
            final Object? v = node[k];
            if (v != null) return v;
          }
          for (final Object? child in node.values) {
            final Object? r = walk(child);
            if (r != null) return r;
          }
        } else if (node is List<Object?>) {
          for (final Object? child in node) {
            final Object? r = walk(child);
            if (r != null) return r;
          }
        }
        return null;
      }

      return walk(j);
    }

    int? toId(Object? v) {
      if (v is num) return v.toInt();
      if (v is String) {
        final String t = v.trim();
        if (t.isEmpty) return null;
        return int.tryParse(t);
      }
      return null;
    }

    final Object? typeRaw = deep(<String>['type', 'shareType']);
    final String type = typeRaw == null ? '' : '$typeRaw'.toLowerCase();
    final int? playlistId = toId(deep(<String>['playlistId'])) ??
        (type.contains('playlist') ? toId(deep(<String>['id'])) : null);
    final int? albumId = toId(deep(<String>['albumId'])) ??
        (type.contains('album') ? toId(deep(<String>['id'])) : null);
    final int? songId = toId(deep(<String>['songId'])) ??
        (type.contains('song') || type == 'music' || type == '0'
            ? toId(deep(<String>['id']))
            : null);
    // 顶层 id 兼容：无显式 type 时按独有键归类
    final int? topId = toId(deep(<String>['id']));
    String kind = '';
    int sid = 0;
    if (playlistId != null && playlistId > 0) {
      kind = 'playlist';
      sid = playlistId;
    } else if (albumId != null && albumId > 0) {
      kind = 'album';
      sid = albumId;
    } else if (songId != null && songId > 0) {
      kind = 'song';
      sid = songId;
    } else if (topId != null && topId > 0) {
      // 仅顶层 id：若有 type 字样按 type，否则按歌处理（send/song 的
      // 历史消息实测形态就是 {"msg":...,"id":...}）
      kind = 'song';
      sid = topId;
    }
    if (kind.isEmpty || sid <= 0) return null;
    final String name = () {
      final Object? v = deep(<String>[
        'songName',
        'albumName',
        'playlistName',
        'name',
        'title',
      ]);
      return v == null ? '' : '$v';
    }();
    // 发送者留言（send/song|album|playlist 的 msg 参数会原样带回）
    final String hint = () {
      final Object? v = deep(<String>['shareMsg', 'reason', 'msg']);
      return v == null ? '' : '$v';
    }();
    return MsgShare(kind: kind, id: sid, name: name, hint: hint);
  }
}

/// 提取 msg 字段实际文本（Zephyr parseMsgField 同款）：
/// 网易云的 msg 可能是：
///  - 纯文本字符串；
///  - JSON 字符串 {"msg":"实际文本",...}（带歌单/歌曲的私信）；
///  - 对象 {msg: ...}。
String parseMsgField(Object? rawMsg) {
  if (rawMsg == null) return '';
  if (rawMsg is String) {
    final String s = rawMsg.trim();
    if (s.startsWith('{')) {
      try {
        final Object? parsed = jsonDecode(s);
        if (parsed is Map<String, Object?>) {
          final Object? m =
              parsed['msg'] ?? parsed['title'] ?? parsed['content'];
          return m == null ? s : '$m';
        }
      } catch (_) {
        return s;
      }
    }
    return s;
  }
  if (rawMsg is Map<String, Object?>) {
    final Object? m = rawMsg['msg'] ?? rawMsg['title'] ?? rawMsg['content'];
    return m == null ? '$rawMsg' : '$m';
  }
  return '$rawMsg';
}

/// 从 msg 字段解析分享卡（song/album/playlist）；无分享信息返回 null。
/// （需求第二十九批：私信带歌曲/带专辑/带歌单 —— 文档
/// /send/song、/send/album、/send/playlist 的接收侧渲染）
MsgShare? parseMsgShare(Object? rawMsg) {
  Object? parsed;
  if (rawMsg is String) {
    final String s = rawMsg.trim();
    if (!s.startsWith('{')) return null;
    try {
      parsed = jsonDecode(s);
    } catch (_) {
      return null;
    }
  } else if (rawMsg is Map<String, Object?>) {
    parsed = rawMsg;
  }
  if (parsed is! Map<String, Object?>) return null;
  return MsgShare.fromJson(parsed);
}

// ---------------------------------------------------------------- 仓库

class MessageRepository {
  MessageRepository(this._api);

  final NeteaseApi _api;

  int _myId = 0;

  /// 会话列表（含最后消息预览与未读数）。登录后调用。
  Future<List<Conversation>> conversations({
    int limit = 30,
    int offset = 0,
  }) async {
    final Map<String, Object?> res = await _api.get(
      '/msg/private',
      <String, String>{
        'limit': '$limit',
        if (offset > 0) 'offset': '$offset',
      },
    );
    await _ensureMyId();
    final Object? msgs = apiPayload(res)['msgs'];
    if (msgs is! List<Object?>) return const <Conversation>[];
    return <Conversation>[
      for (final Object? m in msgs)
        if (m is Map<String, Object?>) Conversation.fromJson(m, _myId),
    ]..removeWhere((Conversation c) => c.userId <= 0);
  }

  /// 聊天记录（最新在前 → 反转为正序返回）。[before] 取上一页：
  /// 传当前最早一条的 time。
  Future<List<ChatMessage>> history(
    int uid, {
    int limit = 30,
    int? before,
  }) async {
    final Map<String, Object?> res = await _api.get(
      '/msg/private/history',
      <String, String>{
        'uid': '$uid',
        'limit': '$limit',
        if (before != null) 'before': '$before',
      },
    );
    await _ensureMyId();
    final Object? msgs = apiPayload(res)['msgs'];
    if (msgs is! List<Object?>) return const <ChatMessage>[];
    final List<ChatMessage> list = <ChatMessage>[
      for (final Object? m in msgs)
        if (m is Map<String, Object?>) ChatMessage.fromJson(m, _myId),
    ];
    return list.reversed.toList(); // 正序：旧在上新在下
  }

  /// 发送文本私信（POST /send/text）。返回错误文案或 null。
  Future<String?> sendText(int userId, String msg) async {
    if (msg.trim().isEmpty) return '消息不能为空';
    try {
      final Map<String, Object?> res = await _api.post(
        '/send/text',
        <String, String>{'user_ids': '$userId', 'msg': msg},
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code == 200) return null;
      return '发送失败：${(res['message'] ?? res['msg'] ?? 'code $code')}';
    } catch (e) {
      return '发送失败：$e';
    }
  }

  /// 发送带歌曲的私信（POST /send/song，需求第二十九批文档接入）。
  Future<String?> sendSong(int userId, int songId, String msg) async {
    return _sendWithId('/send/song', userId, '$songId', msg);
  }

  /// 发送带专辑的私信（POST /send/album，需求第二十九批文档接入）。
  Future<String?> sendAlbum(int userId, int albumId, String msg) async {
    return _sendWithId('/send/album', userId, '$albumId', msg);
  }

  /// 发送带歌单的私信（POST /send/playlist，需求第二十九批文档接入；
  /// 注意该接口参数名是 playlist 而不是 id，且不能发送重复歌单）。
  Future<String?> sendPlaylist(int userId, int playlistId, String msg) async {
    if (msg.trim().isEmpty) return '留言不能为空';
    try {
      final Map<String, Object?> res = await _api.post(
        '/send/playlist',
        <String, String>{
          'user_ids': '$userId',
          'msg': msg,
          'playlist': '$playlistId',
        },
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code == 200) return null;
      return '发送失败：${(res['message'] ?? res['msg'] ?? 'code $code')}';
    } catch (e) {
      return '发送失败：$e';
    }
  }

  /// /send/song 与 /send/album 共用（参数同名 id）
  Future<String?> _sendWithId(
      String path, int userId, String id, String msg) async {
    if (msg.trim().isEmpty) return '留言不能为空';
    try {
      final Map<String, Object?> res = await _api.post(
        path,
        <String, String>{
          'user_ids': '$userId',
          'id': id,
          'msg': msg,
        },
        throwOnCode: false,
      );
      final int code = (res['code'] as num?)?.toInt() ?? 0;
      if (code == 200) return null;
      return '发送失败：${(res['message'] ?? res['msg'] ?? 'code $code')}';
    } catch (e) {
      return '发送失败：$e';
    }
  }

  Future<void> _ensureMyId() async {
    if (_myId > 0) return;
    try {
      final Map<String, Object?> res =
          await _api.get('/login/status', const <String, String>{});
      final Map<String, Object?> data = apiPayload(res);
      final Map<String, Object?>? profile =
          data['profile'] as Map<String, Object?>?;
      _myId = (profile?['userId'] as num?)?.toInt() ?? 0;
    } catch (_) {
      _myId = 0;
    }
  }
}
