/// 播放队列持久化 / 历史快照 / 播放统计 序列化测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/features/library/domain/track.dart';
import 'package:ming_music/features/player/services/queue_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late QueuePersistence persistence;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    persistence = QueuePersistence(prefs);
  });

  Track track(String id, {int? neteaseId, int? mvId}) => Track(
        id: id,
        neteaseId: neteaseId,
        mvId: mvId,
        title: '歌 $id',
        artist: '歌手',
        album: '专辑',
        source: '',
        isNetwork: true,
        fee: 1,
      );

  group('队列状态持久化', () {
    test('save → load 往返一致（含 neteaseId/mvId/fee）', () async {
      final List<Track> queue = <Track>[
        track('a', neteaseId: 111, mvId: 222),
        track('b', neteaseId: 333),
      ];
      await persistence.saveQueueState(queue, 1, '测试歌单');

      final saved = persistence.loadQueueState();
      expect(saved, isNotNull);
      expect(saved!.queue.length, 2);
      expect(saved.queue[0].id, 'a');
      expect(saved.queue[0].neteaseId, 111);
      expect(saved.queue[0].mvId, 222);
      expect(saved.queue[0].fee, 1);
      expect(saved.index, 1);
      expect(saved.queueTitle, '测试歌单');
    });

    test('空存档 / 空队列返回 null，index 越界自动 clamp', () async {
      expect(persistence.loadQueueState(), isNull);
      await persistence.saveQueueState(<Track>[], 0, null);
      expect(persistence.loadQueueState(), isNull);

      await persistence.saveQueueState(<Track>[track('a')], 5, 'x');
      expect(persistence.loadQueueState()!.index, 0);
    });
  });

  group('历史快照（最多3个）', () {
    test('push 去重且最新在前，超过 3 个裁剪最旧', () async {
      await persistence.pushHistory('A', <Track>[track('a1')]);
      await persistence.pushHistory('B', <Track>[track('b1')]);
      await persistence.pushHistory('C', <Track>[track('c1')]);

      List<QueueSnapshot> h = persistence.loadHistory();
      expect(h.map((QueueSnapshot s) => s.title).toList(), <String>['C', 'B', 'A']);

      // 同内容去重：A 重新入队 → 移到最前，不新增
      await persistence.pushHistory('A', <Track>[track('a1')]);
      h = persistence.loadHistory();
      expect(h.length, 3);
      expect(h.first.title, 'A');

      // 第 4 个：裁掉最旧（B）
      await persistence.pushHistory('D', <Track>[track('d1')]);
      h = persistence.loadHistory();
      expect(h.length, 3);
      expect(h.map((QueueSnapshot s) => s.title).toList(),
          <String>['D', 'A', 'C']);
    });

    test('removeAt 删除指定快照', () async {
      await persistence.pushHistory('A', <Track>[track('a1')]);
      await persistence.pushHistory('B', <Track>[track('b1')]);
      await persistence.removeAt(0);
      expect(persistence.loadHistory().single.title, 'A');
    });

    test('Track 序列化字段完整恢复（需求：播放列表持久化）', () async {
      await persistence.pushHistory('T', <Track>[
        track('x', neteaseId: 42, mvId: 7),
      ]);
      final QueueSnapshot snap = persistence.loadHistory().single;
      expect(snap.tracks.first.neteaseId, 42);
      expect(snap.tracks.first.mvId, 7);
      expect(snap.tracks.first.isNetwork, isTrue);
    });
  });

  group('播放统计', () {
    test('increment 累计计数', () async {
      await persistence.incrementPlay(100);
      await persistence.incrementPlay(100);
      await persistence.incrementPlay(200);
      final Map<int, int> stats = persistence.loadPlayStats();
      expect(stats[100], 2);
      expect(stats[200], 1);
    });
  });
}
