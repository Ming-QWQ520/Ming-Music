/// 第二十七批测试：「房主却是我」恶性 Bug 根治。
///
/// Bug 链：网易 room/create 对已在房账号会原样返回当前所在房间 ——
/// 访客加入好友房间后（或杀进程重开、本地状态丢失而服务端会话仍在）
/// 再触发创建，本地就会把自己误置为房主，还会覆盖房主队列。
///
/// 覆盖：
///  - ListenServerRoom.iAmHost：服务端权威房主判定（缺字段不猜）；
///  - extractListenHostId：顶层整型字段 / roomUsers 布尔 / 角色枚举 /
///    无字段返回 null 的宽容解析；
///  - ListenTogetherService.resumeRoom：恢复姿态回填（roomId/inviterId/
///    isCreator）；
///  - ListenTogetherService.createRoom：本地持房硬防护（无需网络即拒绝，
///    杜绝「访客误创建被服务端返回所在房间」的误置房主路径）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ming_music/core/api/netease_api.dart';
import 'package:ming_music/features/listen/services/listen_together_service.dart';

void main() {
  group('ListenServerRoom.iAmHost（服务端权威角色判定）', () {
    test('hostId == 我 → 房主', () {
      const ListenServerRoom r = ListenServerRoom(
        roomId: 'abc_123',
        users: <ListenRoomUser>[],
        hostId: 111,
        myUserId: 111,
      );
      expect(r.iAmHost, isTrue);
    });

    test('hostId == 好友 → 访客', () {
      const ListenServerRoom r = ListenServerRoom(
        roomId: 'abc_123',
        users: <ListenRoomUser>[],
        hostId: 222,
        myUserId: 111,
      );
      expect(r.iAmHost, isFalse);
    });

    test('服务端无房主字段（hostId=null）→ 不猜，按访客', () {
      // 宁可按访客恢复也不误判房主 —— 「房主却是我」的防线核心
      const ListenServerRoom r = ListenServerRoom(
        roomId: 'abc_123',
        users: <ListenRoomUser>[],
        hostId: null,
        myUserId: 111,
      );
      expect(r.iAmHost, isFalse);
    });
  });

  group('extractListenHostId（宽容房主字段解析）', () {
    test('顶层整型字段逐个命中', () {
      for (final String k in const <String>[
        'hostUserId',
        'hostId',
        'creatorId',
        'createUserId',
        'ownerId',
        'roomOwnerId',
        'anchorUserId',
      ]) {
        expect(
          extractListenHostId(<String, Object?>{k: 222}),
          222,
          reason: '键 $k 应被识别为房主字段',
        );
      }
    });

    test('顶层字段为字符串数字也可解析', () {
      expect(
        extractListenHostId(<String, Object?>{'hostUserId': '222'}),
        222,
      );
    });

    test('顶层非法值（0/负数/垃圾字符串）不误判', () {
      expect(extractListenHostId(<String, Object?>{'hostId': 0}), isNull);
      expect(extractListenHostId(<String, Object?>{'hostId': -5}), isNull);
      expect(extractListenHostId(<String, Object?>{'hostId': 'null'}), isNull);
    });

    test('roomUsers 项 isHost=true 命中', () {
      final int? hostId = extractListenHostId(<String, Object?>{
        'roomUsers': <Object?>[
          <String, Object?>{'userId': 111, 'nickname': '我'},
          <String, Object?>{'userId': 222, 'isHost': true, 'nickname': '房主'},
        ],
      });
      expect(hostId, 222);
    });

    test('roomUsers 项 userType=1 命中（网易常见约定 1=房主）', () {
      final int? hostId = extractListenHostId(<String, Object?>{
        'roomUsers': <Object?>[
          <String, Object?>{'userId': 111, 'userType': 0},
          <String, Object?>{'userId': 222, 'userType': 1},
        ],
      });
      expect(hostId, 222);
    });

    test('roomUsers 项 role=1 命中', () {
      final int? hostId = extractListenHostId(<String, Object?>{
        'roomUsers': <Object?>[
          <String, Object?>{'userId': 333, 'role': 1},
        ],
      });
      expect(hostId, 333);
    });

    test('无房主字段返回 null（宁可访客也不误判）', () {
      expect(extractListenHostId(null), isNull);
      expect(extractListenHostId(<String, Object?>{}), isNull);
      expect(
        extractListenHostId(<String, Object?>{
          'roomId': 'abc_123',
          'roomUsers': <Object?>[
            <String, Object?>{'userId': 111, 'nickname': '我'},
            <String, Object?>{'userId': 222, 'nickname': '好友'},
          ],
        }),
        isNull,
      );
    });

    test('成员项缺 userId 时不崩不误判', () {
      final int? hostId = extractListenHostId(<String, Object?>{
        'roomUsers': <Object?>[
          <String, Object?>{'isHost': true, 'nickname': '无id'},
        ],
      });
      expect(hostId, isNull);
    });
  });

  group('ListenTogetherService.resumeRoom + createRoom 硬防护', () {
    test('resumeRoom 以恢复姿态回填角色与凭据（不触发任何网络）', () async {
      final ListenTogetherService svc =
          ListenTogetherService(await _FakeApi.create());
      // 模拟：服务端指认我是访客（好友房主 id=222）
      svc.resumeRoom(roomId: 'roomA', inviterId: 222, isCreator: false);
      expect(svc.inRoom, isTrue);
      expect(svc.roomId, 'roomA');
      expect(svc.inviterId, 222);
      expect(svc.isCreator, isFalse);
      // 模拟：服务端指认我是房主
      svc.resumeRoom(roomId: 'roomB', inviterId: 111, isCreator: true);
      expect(svc.roomId, 'roomB');
      expect(svc.inviterId, 111);
      expect(svc.isCreator, isTrue);
    });

    test('本地持房时 createRoom 直接拒绝（根治访客误创建误置房主）', () async {
      final ListenTogetherService svc =
          ListenTogetherService(await _FakeApi.create());
      // 访客姿态恢复好友房间后再点「发起一起听」→ 必须拒绝而非调 create
      svc.resumeRoom(roomId: 'roomA', inviterId: 222, isCreator: false);
      final String? err = await svc.createRoom();
      expect(err, contains('已在一间一起听房间中'));
      // 房间状态不被污染（仍持好友房间）
      expect(svc.roomId, 'roomA');
      expect(svc.isCreator, isFalse);
    });

    test('房主持房时 createRoom 同样拒绝重复创建', () async {
      final ListenTogetherService svc =
          ListenTogetherService(await _FakeApi.create());
      svc.resumeRoom(roomId: 'roomB', inviterId: 111, isCreator: true);
      final String? err = await svc.createRoom();
      expect(err, contains('已在一间一起听房间中'));
      expect(svc.roomId, 'roomB');
      expect(svc.isCreator, isTrue);
    });

    test('未持房时 createRoom 走登录检查（离线返回登录失败而非误建房）', () async {
      final ListenTogetherService svc =
          ListenTogetherService(await _FakeApi.create());
      final String? err = await svc.createRoom();
      // 离线环境下 ensureLogin 失败 —— 但绝不能带出 roomId/房主态
      expect(err, isNotNull);
      expect(svc.inRoom, isFalse);
      expect(svc.isCreator, isFalse);
    });
  });
}

/// 最小假 API：所有请求都抛错（离线单测环境，覆盖失败路径）
class _FakeApi extends NeteaseApi {
  _FakeApi(super.prefs);

  static Future<_FakeApi> create() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return _FakeApi(await SharedPreferences.getInstance());
  }

  @override
  Future<Map<String, Object?>> get(
    String path,
    Map<String, String> params, {
    Set<int>? allowedCodes,
    bool throwOnCode = true,
    Map<String, String>? cookieKv,
  }) async =>
      throw Exception('offline');

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> params, {
    bool throwOnCode = true,
  }) async =>
      throw Exception('offline');
}
