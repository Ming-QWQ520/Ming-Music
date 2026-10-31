/// 第二十六批测试：私信数据模型 + 一起听命令判重/加入对齐。
///
/// 覆盖：
///  - parseMsgField：网易 msg 字段的三种形态（纯文本 / JSON 字符串 /
///    对象）与空值 —— 对齐 Zephyr MessageView 的解析语义；
///  - ChatMessage.fromJson：我方判定 + 一起听邀请识别（深链/邀请串/
///    网易云官方分享链接夹在正文中）；
///  - Conversation.fromJson：对方识别（fromUser/toUser 取非己方）；
///  - ListenPlayCommand.identity：同一命令元组稳定（serverSeq 变化
///    不影响判重）+ 不同命令元组不同；
///  - parseListenInvite：真实 roomId（hex32_时间戳）邀请串不丢前缀。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ming_music/features/listen/providers/listen_room_provider.dart';
import 'package:ming_music/features/listen/services/listen_together_service.dart';
import 'package:ming_music/features/social/data/message_repository.dart';

void main() {
  group('parseMsgField（Zephyr 同款解析）', () {
    test('纯文本原样返回', () {
      expect(parseMsgField('今晚一起听歌吗'), '今晚一起听歌吗');
    });

    test('JSON 字符串提取 msg 字段', () {
      expect(
        parseMsgField('{"msg":"实际文本","type":1}'),
        '实际文本',
      );
    });

    test('JSON 字符串无 msg 时回退 title/content', () {
      expect(parseMsgField('{"title":"歌单分享"}'), '歌单分享');
      expect(parseMsgField('{"content":"内容"}'), '内容');
    });

    test('对象形态提取', () {
      expect(parseMsgField(<String, Object?>{'msg': '对象消息'}), '对象消息');
    });

    test('非 JSON 的 { 开头文本原样返回', () {
      expect(parseMsgField('{不是json'), '{不是json');
    });

    test('空值返回空串', () {
      expect(parseMsgField(null), '');
      expect(parseMsgField(''), '');
    });
  });

  group('ChatMessage.fromJson', () {
    final Map<String, Object?> fromUser = <String, Object?>{
      'userId': 111,
      'nickname': '对方',
      'avatarUrl': 'http://p.example/a.jpg',
    };

    test('对方消息识别 + 纯文本', () {
      final ChatMessage m = ChatMessage.fromJson(<String, Object?>{
        'id': 7,
        'fromUser': fromUser,
        'toUser': <String, Object?>{'userId': 222},
        'msg': '你好',
        'time': 1793445000000,
      }, 222);
      expect(m.isSelf, isFalse);
      expect(m.fromUserId, 111);
      expect(m.content, '你好');
      expect(m.invite, isNull);
    });

    test('我方消息识别', () {
      final ChatMessage m = ChatMessage.fromJson(<String, Object?>{
        'id': 8,
        'fromUser': fromUser,
        'msg': '我发的',
        'time': 1793445000001,
      }, 111);
      expect(m.isSelf, isTrue);
    });

    test('深链消息识别为一起听邀请', () {
      final ChatMessage m = ChatMessage.fromJson(<String, Object?>{
        'id': 9,
        'fromUser': fromUser,
        'msg': '点击加入：mingmusic://listen/join?roomId=abc123&inviterId=111',
        'time': 1793445000002,
      }, 222);
      expect(m.invite, isNotNull);
      expect(m.invite!.roomId, 'abc123');
      expect(m.invite!.inviterId, 111);
    });

    test('邀请串夹在整段分享文本中也识别', () {
      const String rid = '057eb172ecb5eff6b23464510a241f79_1793444501';
      final ChatMessage m = ChatMessage.fromJson(<String, Object?>{
        'id': 10,
        'fromUser': fromUser,
        'msg': '【MingMusic 一起听】…邀请码：$rid|111',
        'time': 1793445000003,
      }, 222);
      expect(m.invite, isNotNull);
      expect(m.invite!.roomId, rid);
      expect(m.invite!.inviterId, 111);
    });

    test('普通聊天不误判为邀请', () {
      final ChatMessage m = ChatMessage.fromJson(<String, Object?>{
        'id': 11,
        'fromUser': fromUser,
        'msg': '今天天气不错 123|456 不是邀请码（位数不足）',
        'time': 1793445000004,
      }, 222);
      // 123 位数 < 4 → 不满足邀请串正则
      expect(m.invite, isNull);
    });
  });

  group('Conversation.fromJson', () {
    test('fromUser 是对方（fromUser 非己方时取 fromUser）', () {
      final Conversation c = Conversation.fromJson(<String, Object?>{
        'fromUser': <String, Object?>{
          'userId': 111,
          'nickname': '对方',
          'avatarUrl': 'http://p.example/a.jpg',
        },
        'toUser': <String, Object?>{'userId': 222, 'nickname': '我'},
        'lastMsg': '嗨',
        'lastMsgTime': 1793445000000,
        'newMsgCount': 3,
      }, 222);
      expect(c.userId, 111);
      expect(c.nickname, '对方');
      expect(c.lastMsg, '嗨');
      expect(c.newMsgCount, 3);
    });

    test('fromUser 是自己时取 toUser 为对方', () {
      final Conversation c = Conversation.fromJson(<String, Object?>{
        'fromUser': <String, Object?>{'userId': 222, 'nickname': '我'},
        'toUser': <String, Object?>{'userId': 333, 'nickname': 'TA'},
        'lastMsg': '在吗',
      }, 222);
      expect(c.userId, 333);
      expect(c.nickname, 'TA');
    });

    test('匿名号昵称为空由展示层兜底（解析保留空串）', () {
      final Conversation c = Conversation.fromJson(<String, Object?>{
        'fromUser': <String, Object?>{'userId': 444, 'nickname': null},
        'lastMsg': 'x',
      }, 222);
      expect(c.nickname, '');
      expect(c.userId, 444);
    });
  });

  group('parseListenInvite：真实 roomId 形态（hex32_时间戳）', () {
    const String rid = '057eb172ecb5eff6b23464510a241f79_1793444501';

    test('纯邀请串不丢 hex 前缀（第二十六批修复点）', () {
      final ListenInvite? invite = parseListenInvite('$rid|36547588');
      expect(invite, isNotNull);
      expect(invite!.roomId, rid);
      expect(invite.inviterId, 36547588);
    });

    test('夹在整段分享文本中优先取深链（完整 roomId）', () {
      const String text = '【MingMusic 一起听】点击链接加入房间：\n'
          'mingmusic://listen/join?roomId=$rid&inviterId=36547588\n\n'
          '邀请码：$rid|36547588';
      final ListenInvite? invite = parseListenInvite(text);
      expect(invite, isNotNull);
      expect(invite!.roomId, rid);
      expect(invite.inviterId, 36547588);
    });

    test('旧纯数字 roomId 兼容', () {
      final ListenInvite? invite = parseListenInvite('1873123456789|36547588');
      expect(invite, isNotNull);
      expect(invite!.roomId, '1873123456789');
    });
  });

  group('ListenPlayCommand.identity（判重元组）', () {
    ListenPlayCommand cmd({
      int userId = 111,
      String type = 'GOTO',
      int song = 186016,
      int progress = 4242,
      String status = 'PLAY',
      int serverSeq = 1793444806105,
      int clientSeq = 3,
    }) =>
        ListenPlayCommand(
          userId: userId,
          commandType: type,
          targetSongId: song,
          progressMs: progress,
          playStatus: status,
          serverSeq: serverSeq,
          clientSeq: clientSeq,
          receivedAt: DateTime.now(),
        );

    test('同一命令 serverSeq 变化后元组仍相同（判重不失效）', () {
      // 实测：同一命令两次读取 serverSeq 不同（服务端时间戳），
      // 元组判重必须不受 serverSeq 影响
      final ListenPlayCommand a = cmd(serverSeq: 1793444806105);
      final ListenPlayCommand b = cmd(serverSeq: 1793444943933);
      expect(a.identity, b.identity);
    });

    test('不同命令元组不同', () {
      expect(cmd().identity, isNot(cmd(progress: 999).identity));
      expect(cmd().identity, isNot(cmd(song: 28815250).identity));
      expect(cmd().identity, isNot(cmd(type: 'PAUSE').identity));
      expect(cmd().identity, isNot(cmd(clientSeq: 4).identity));
    });

    test('加入对齐命令（clientSeq=0）可与其他命令区分', () {
      final ListenPlayCommand align =
          cmd(userId: 222, clientSeq: 0, serverSeq: 0);
      expect(align.clientSeq, 0);
      expect(align.identity, isNot(cmd().identity));
    });
  });
}
