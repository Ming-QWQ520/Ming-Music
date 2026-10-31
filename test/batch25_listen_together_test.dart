/// 第二十五批一起听闭环测试：邀请串构造与宽容解析。
///
/// 覆盖「好友可点击加入」的两条通路：
///  - 深链 mingmusic://listen/join?roomId=&inviterId=（可点击场景）；
///  - 邀请串 房间号|邀请人ID（微信等无法点击 scheme 的场景，
///    复制整段聊天文本粘贴也能识别）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ming_music/features/listen/providers/listen_room_provider.dart';

void main() {
  group('buildListenInviteLink', () {
    test('生成标准深链', () {
      expect(
        buildListenInviteLink('1873123456789', 36547588),
        'mingmusic://listen/join?roomId=1873123456789&inviterId=36547588',
      );
    });
  });

  group('parseListenInvite', () {
    test('深链原样解析', () {
      final ListenInvite? invite =
          parseListenInvite('mingmusic://listen/join?roomId=1873123456789'
              '&inviterId=36547588');
      expect(invite, isNotNull);
      expect(invite!.roomId, '1873123456789');
      expect(invite.inviterId, 36547588);
    });

    test('深链大小写/空白容忍', () {
      final ListenInvite? invite =
          parseListenInvite('MINGMUSIC://listen/join? roomId = 1873 '
              '& INVITERID = 42');
      expect(invite, isNotNull);
      expect(invite!.roomId, '1873');
      expect(invite.inviterId, 42);
    });

    test('纯邀请串', () {
      final ListenInvite? invite = parseListenInvite('1873123456789|36547588');
      expect(invite, isNotNull);
      expect(invite!.roomId, '1873123456789');
      expect(invite.inviterId, 36547588);
    });

    test('邀请串夹在整段分享文本中（微信复制粘贴场景）', () {
      const String text = '【MingMusic 一起听】点击链接加入房间，和我同步听歌：\n'
          'mingmusic://listen/join?roomId=1873123456789&inviterId=36547588\n\n'
          '若链接无法点击：复制下面这串邀请码，打开 MingMusic → 我的 → 一起听 → '
          '「加入一起听」粘贴即可：\n'
          '1873123456789|36547588';
      final ListenInvite? invite = parseListenInvite(text);
      expect(invite, isNotNull);
      expect(invite!.roomId, '1873123456789');
      expect(invite.inviterId, 36547588);
    });

    test('中文全角分隔符｜同样识别', () {
      final ListenInvite? invite = parseListenInvite('1873123456789｜36547588');
      expect(invite, isNotNull);
      expect(invite!.inviterId, 36547588);
    });

    test('非法输入返回 null', () {
      expect(parseListenInvite(''), isNull);
      expect(parseListenInvite('随便一段话没有邀请'), isNull);
      expect(parseListenInvite('mingmusic://listen/join?roomId=1'), isNull);
      expect(parseListenInvite('1873123456789|'), isNull);
      expect(parseListenInvite('abc|def'), isNull);
    });
  });

  group('buildListenShareText', () {
    test('分享文本同时包含深链与邀请串兜底', () {
      final String text = buildListenShareText('1873123456789', 36547588);
      expect(
          text,
          contains('mingmusic://listen/join?roomId=1873123456789'
              '&inviterId=36547588'));
      expect(text, contains('1873123456789|36547588'));
      // 分享全文必须能被自己的解析器还原（闭环一致性）
      final ListenInvite? invite = parseListenInvite(text);
      expect(invite, isNotNull);
      expect(invite!.roomId, '1873123456789');
      expect(invite.inviterId, 36547588);
    });
  });
}
