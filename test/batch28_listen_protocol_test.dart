/// 第二十八批一起听协议单测：
///
/// 背景（用户实测「完全都是各听各的」「切换歌单不同步」）：
///  - 写通路参数包装（commandInfo/playlistParam）按 api-enhanced 模块
///    源码实证修正（包装逻辑内联在请求方法里，网络层难 mock，此处
///    覆盖同样关键的**读通路深度解析**纯函数）；
///  - 读通路响应结构在不同部署/版本间差异大 → extractSongIds /
///    extractPlayCommand 必须对任意层级/字段形态宽容。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/features/listen/services/listen_together_service.dart';

void main() {
  group('extractSongIds（房间队列深度解析）', () {
    test('数组形态（displayList 直接是 id 列表）', () {
      final List<int> ids = ListenTogetherService.extractSongIds(
        <String, Object?>{
          'playList': <String, Object?>{
            'displayList': <Object?>[101, 202, 303],
          },
        },
      );
      expect(ids, <int>[101, 202, 303]);
    });

    test('CSV 字符串形态', () {
      final List<int> ids = ListenTogetherService.extractSongIds(
        <String, Object?>{
          'playList': <String, Object?>{'displayList': '11,22,33'},
        },
      );
      expect(ids, <int>[11, 22, 33]);
    });

    test('对象元素形态（{id} / {songId}）', () {
      final List<int> ids = ListenTogetherService.extractSongIds(
        <String, Object?>{
          'playList': <String, Object?>{
            'displayList': <Object?>[
              <String, Object?>{'id': 5},
              <String, Object?>{'songId': 6},
            ],
          },
        },
      );
      expect(ids, <int>[5, 6]);
    });

    test('字符串数字元素', () {
      final List<int> ids = ListenTogetherService.extractSongIds(
        <String, Object?>{
          'displayList': <Object?>['701', '802', 'oops'],
        },
      );
      expect(ids, <int>[701, 802]);
    });

    test('深层嵌套包裹（data.roomInfo.playList.displayList）', () {
      final List<int> ids = ListenTogetherService.extractSongIds(
        <String, Object?>{
          'code': 200,
          'data': <String, Object?>{
            'roomInfo': <String, Object?>{
              'roomId': 'r1',
              'playList': <String, Object?>{
                'displayList': <Object?>[9],
              },
            },
          },
        },
      );
      expect(ids, <int>[9]);
    });

    test('无 displayList 时回退 randomList', () {
      final List<int> ids = ListenTogetherService.extractSongIds(
        <String, Object?>{
          'playList': <String, Object?>{
            'randomList': <Object?>[42]
          },
        },
      );
      expect(ids, <int>[42]);
    });

    test('非法 id（<=0 / 解析失败）被剔除，全无效返回空', () {
      final List<int> ids = ListenTogetherService.extractSongIds(
        <String, Object?>{
          'displayList': <Object?>[0, -3, 'x', 8],
        },
      );
      expect(ids, <int>[8]);
      expect(
        ListenTogetherService.extractSongIds(<String, Object?>{
          'displayList': <Object?>[0, -3],
        }),
        isEmpty,
      );
      expect(
        ListenTogetherService.extractSongIds(<String, Object?>{'code': 200}),
        isEmpty,
      );
    });
  });

  group('extractPlayCommand（读通路命令深度解析）', () {
    test('顶层 playCommand', () {
      final ListenPlayCommand? cmd =
          ListenTogetherService.extractPlayCommand(<String, Object?>{
        'playCommand': <String, Object?>{
          'userId': 111,
          'commandType': 'GOTO',
          'targetSongId': 222,
          'progress': '30000',
          'playStatus': 'PLAY',
          'serverSeq': 7,
          'clientSeq': 3,
        },
      });
      expect(cmd, isNotNull);
      expect(cmd!.userId, 111);
      expect(cmd.commandType, 'GOTO');
      expect(cmd.targetSongId, 222);
      expect(cmd.progressMs, 30000);
      expect(cmd.playStatus, 'PLAY');
      expect(cmd.clientSeq, 3);
    });

    test('commandHead+commandInfo 分层结构（字段合并）', () {
      final ListenPlayCommand? cmd =
          ListenTogetherService.extractPlayCommand(<String, Object?>{
        'playList': <String, Object?>{
          'playCommand': <String, Object?>{
            'commandHead': <String, Object?>{
              'userId': 333,
              'serverSeq': '12',
            },
            'commandInfo': <String, Object?>{
              'commandType': 'PLAY',
              'targetSongId': '444',
              'progress': 5000,
              'playStatus': 'PAUSE',
              'clientSeq': 2,
            },
          },
        },
      });
      expect(cmd, isNotNull);
      expect(cmd!.userId, 333);
      expect(cmd.commandType, 'PLAY');
      expect(cmd.targetSongId, 444);
      expect(cmd.progressMs, 5000);
      expect(cmd.playStatus, 'PAUSE');
      expect(cmd.serverSeq, 12);
      expect(cmd.clientSeq, 2);
    });

    test('REPLACE 等队列型命令被跳过，优先取播放型', () {
      final ListenPlayCommand? cmd =
          ListenTogetherService.extractPlayCommand(<String, Object?>{
        'playCommand': <String, Object?>{
          'commandType': 'REPLACE',
          'serverSeq': 1,
        },
        'playlist': <String, Object?>{
          'playCommand': <String, Object?>{
            'userId': 9,
            'commandType': 'PROGRESS',
            'targetSongId': 8,
            'progress': 1000,
            'playStatus': 'PLAY',
            'serverSeq': 2,
          },
        },
      });
      expect(cmd, isNotNull);
      expect(cmd!.commandType, 'PROGRESS');
      expect(cmd.targetSongId, 8);
    });

    test('全无播放型命令时回退第一条（含 REPLACE）', () {
      final ListenPlayCommand? cmd =
          ListenTogetherService.extractPlayCommand(<String, Object?>{
        'playCommand': <String, Object?>{
          'commandType': 'REPLACE',
          'serverSeq': 1,
        },
      });
      expect(cmd, isNotNull);
      expect(cmd!.commandType, 'REPLACE');
      expect(cmd.targetSongId, 0); // 上层按 targetSongId=0 忽略
    });

    test('无命令返回 null', () {
      expect(
        ListenTogetherService.extractPlayCommand(<String, Object?>{
          'code': 200,
          'data': <String, Object?>{'roomId': 'r'},
        }),
        isNull,
      );
    });

    test('命令身份元组不包含 serverSeq（判重稳定）', () {
      final ListenPlayCommand a =
          ListenTogetherService.extractPlayCommand(<String, Object?>{
        'playCommand': <String, Object?>{
          'userId': 1,
          'commandType': 'GOTO',
          'targetSongId': 2,
          'progress': 3,
          'playStatus': 'PLAY',
          'serverSeq': 100,
          'clientSeq': 0,
        },
      })!;
      final ListenPlayCommand b =
          ListenTogetherService.extractPlayCommand(<String, Object?>{
        'playCommand': <String, Object?>{
          'userId': 1,
          'commandType': 'GOTO',
          'targetSongId': 2,
          'progress': 3,
          'playStatus': 'PLAY',
          'serverSeq': 999, // serverSeq 变化（服务端时间戳）
          'clientSeq': 0,
        },
      })!;
      expect(a.identity, b.identity);
    });
  });
}
