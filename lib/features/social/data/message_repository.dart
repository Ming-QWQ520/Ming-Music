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
  });

  final String id;
  final int fromUserId;
  final int toUserId;
  final String content;
  final int time;
  final bool isSelf;

  /// 非空 = 消息含一起听邀请（聊天页渲染成点击即加入的卡片）
  final ListenInvite? invite;

  static ChatMessage fromJson(Map<String, Object?> j, int myId) {
    final Map<String, Object?>? from = j['fromUser'] as Map<String, Object?>?;
    final Map<String, Object?>? to = j['toUser'] as Map<String, Object?>?;
    final int fromId = (from?['userId'] as num?)?.toInt() ?? 0;
    final String content = parseMsgField(j['msg']);
    return ChatMessage(
      id: '${j['id'] ?? j['time'] ?? content.hashCode}',
      fromUserId: fromId,
      toUserId: (to?['userId'] as num?)?.toInt() ?? 0,
      content: content,
      time: (j['time'] as num?)?.toInt() ?? 0,
      isSelf: fromId == myId,
      invite: parseListenInvite(content),
    );
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
