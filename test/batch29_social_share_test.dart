/// 第二十九批单测：
///
///  - 私信分享卡解析（parseMsgShare / MsgShare）：send/song、send/album、
///    send/playlist 的历史消息 msg 字段宽容解析（文档「发送私信(带歌曲 /
///    带专辑 / 带歌单)」接入的接收侧）；
///  - 私信未读遮罩（点开联系人消除红点 / 一键已读后服务端旧未读不复现）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/features/social/data/message_repository.dart';
import 'package:ming_music/features/social/providers/message_providers.dart';

void main() {
  group('parseMsgShare（私信分享卡解析）', () {
    test('纯文本消息不产生分享卡', () {
      expect(parseMsgShare('我在用 MingMusic 和你一起听歌'), isNull);
      expect(parseMsgShare(null), isNull);
      expect(parseMsgShare('{"不是json'), isNull);
    });

    test('send/song 历史形态：顶层 id + msg 文本', () {
      final MsgShare? s = parseMsgShare('{"msg":"给你分享一个歌曲","id":351318}');
      expect(s, isNotNull);
      expect(s!.kind, 'song');
      expect(s.id, 351318);
      // msg 是发送者留言（hint），不是歌名 —— 歌名缺失时由卡片兜底展示
      expect(s.name, '');
      expect(s.hint, '给你分享一个歌曲');
    });

    test('type=song 显式标注', () {
      final MsgShare? s =
          parseMsgShare('{"msg":"听这个","type":"song","id":"436514312"}');
      expect(s!.kind, 'song');
      expect(s.id, 436514312);
    });

    test('type=album 显式标注', () {
      final MsgShare? s =
          parseMsgShare('{"msg":"专辑分享","type":"album","id":12345}');
      expect(s!.kind, 'album');
      expect(s.id, 12345);
    });

    test('albumId 独有键优先于 type 缺省', () {
      final MsgShare? s =
          parseMsgShare('{"msg":"...","albumId":998877,"songName":"某歌"}');
      expect(s!.kind, 'album');
      expect(s.id, 998877);
      expect(s.name, '某歌');
    });

    test('playlistId / playlistName（带歌单私信）', () {
      final MsgShare? s = parseMsgShare(
          '{"msg":"歌单给你","playlistId":705123491,"playlistName":"夜跑歌单"}');
      expect(s!.kind, 'playlist');
      expect(s.id, 705123491);
      expect(s.name, '夜跑歌单');
    });

    test('嵌套对象形态（song:{} 包裹）', () {
      final MsgShare? s = parseMsgShare(
          '{"msg":"...","song":{"id":5566,"name":"嵌套歌名"},"type":"song"}');
      expect(s!.kind, 'song');
      expect(s.id, 5566);
      expect(s.name, '嵌套歌名');
    });

    test('无任何 id 字段不产生分享卡', () {
      expect(parseMsgShare('{"msg":"只有文字"}'), isNull);
    });
  });

  group('parseMsgField（分享消息的文本提取不受影响）', () {
    test('JSON 串提取 msg 字段', () {
      expect(
        parseMsgField('{"msg":"给你分享一个歌曲","id":351318}'),
        '给你分享一个歌曲',
      );
    });
  });

  group('ConversationsState 未读遮罩（第二十九批需求）', () {
    Conversation conv(int uid, int unread) => Conversation(
          userId: uid,
          nickname: 'u$uid',
          newMsgCount: unread,
        );

    test('clearUnread 将指定会话红点归零并进入遮罩', () {
      ConversationsState st =
          ConversationsState(items: <Conversation>[conv(1, 3), conv(2, 5)]);
      expect(st.unreadTotal, 8);
      st = st.copyWith(clearedUserIds: <int>{...st.clearedUserIds, 1});
      expect(
          st.maskedItems
              .firstWhere((Conversation c) => c.userId == 1)
              .newMsgCount,
          0);
      expect(
          st.maskedItems
              .firstWhere((Conversation c) => c.userId == 2)
              .newMsgCount,
          5);
      expect(st.unreadTotal, 8); // unreadTotal 仍按原始数据（磁贴侧由 maskedItems 渲染）
      expect(
          st.maskedItems
              .fold<int>(0, (int a, Conversation c) => a + c.newMsgCount),
          5);
    });

    test('markAllRead 全部遮罩', () {
      ConversationsState st = ConversationsState(
        items: <Conversation>[conv(1, 3), conv(2, 5), conv(3, 0)],
      );
      st = st.copyWith(
        clearedUserIds: <int>{
          ...st.clearedUserIds,
          for (final Conversation c in st.items) c.userId,
        },
      );
      expect(
          st.maskedItems.every((Conversation c) => c.newMsgCount == 0), isTrue);
      expect(
          st.maskedItems
              .fold<int>(0, (int a, Conversation c) => a + c.newMsgCount),
          0);
    });

    test('遮罩内会话刷新拉回旧未读不复现', () {
      final ConversationsState st = ConversationsState(
        items: <Conversation>[conv(1, 3)],
        clearedUserIds: const <int>{1},
      );
      // 模拟 load() 拉回服务端仍报 3 的旧数据（items 更新但遮罩保留）
      final ConversationsState reloaded = st.copyWith(
        items: <Conversation>[conv(1, 3)],
      );
      expect(reloaded.maskedItems.first.newMsgCount, 0);
    });
  });
}
