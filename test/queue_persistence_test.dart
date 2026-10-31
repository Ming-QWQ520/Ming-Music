/// 播放队列持久化 / 历史快照 / 播放统计 序列化测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/storage/prefs_keys.dart';
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
    test('v3：网易云曲目落盘元数据（重启直显真实歌名/封面），直链仍置空', () async {
      final List<Track> queue = <Track>[
        track('netease_111', neteaseId: 111, mvId: 222).copyWith(
            cover: 'https://p1.music.126.net/x.jpg', durationMs: 210000),
        track('netease_333', neteaseId: 333),
      ];
      await persistence.saveQueueState(queue, 1, '测试歌单');

      final saved = persistence.loadQueueState();
      expect(saved, isNotNull);
      expect(saved!.queue.length, 2);
      expect(saved.hasNeteaseIds, isTrue);
      expect(saved.queue[0].neteaseId, 111);
      expect(saved.queue[1].neteaseId, 333);
      // 第十七批：元数据随存档恢复 —— Mini 条不再显示「加载中…」
      expect(saved.queue[0].title, '歌 netease_111');
      expect(saved.queue[0].cover, 'https://p1.music.126.net/x.jpg');
      expect(saved.queue[0].durationMs, 210000);
      expect(saved.queue[0].fee, 1);
      expect(saved.queue[0].mvId, 222);
      // 直链不落盘（20 分钟过期），恢复后由 restore 阶段重新解析
      expect(saved.queue[0].source, isEmpty);
      expect(saved.queue[0].needsUrlResolve, isTrue);
      expect(saved.index, 1);
      expect(saved.queueTitle, '测试歌单');
    });

    test('v2 旧档兼容：纯 id 恢复为「加载中…」占位（restore 阶段补全）', () async {
      const String v2Json = '{"v":2,"items":[111,333],"index":1,'
          '"queueTitle":"v2旧档"}';
      await prefs.setString(PrefsKeys.queueState, v2Json);
      final saved = persistence.loadQueueState();
      expect(saved, isNotNull);
      expect(saved!.queue.length, 2);
      expect(saved.queue[0].neteaseId, 111);
      expect(saved.queue[0].title, '加载中…');
      expect(saved.queue[1].neteaseId, 333);
      expect(saved.hasNeteaseIds, isTrue);
      expect(saved.index, 1);
      expect(saved.queueTitle, 'v2旧档');
    });

    test('v2：本地/自定义曲目保存完整数据', () async {
      final List<Track> queue = <Track>[
        Track(
          id: 'local_1',
          title: '本地歌',
          artist: '本机',
          album: '本地专辑',
          source: '/sdcard/Music/a.mp3',
          isNetwork: false,
        ),
      ];
      await persistence.saveQueueState(queue, 0, '本地');
      final saved = persistence.loadQueueState();
      expect(saved, isNotNull);
      expect(saved!.queue.single.id, 'local_1');
      expect(saved.queue.single.title, '本地歌');
      expect(saved.queue.single.source, '/sdcard/Music/a.mp3');
      expect(saved.hasNeteaseIds, isFalse);
    });

    test('旧格式（v1）兼容：网易云曲目清除过期直链强制刷新', () async {
      // 模拟 v1 存档：完整 Track 含已过期直链
      const String legacyJson = '{"queue":['
          '{"id":"netease_42","neteaseId":42,"mvId":0,"title":"旧歌",'
          '"artist":"旧歌手","album":"旧专辑","source":"http://cdn.expired/a.mp3",'
          '"isNetwork":true,"isCustom":false,"fee":0}'
          '],"index":0,"queueTitle":"旧格式"}';
      await prefs.setString(PrefsKeys.queueState, legacyJson);

      final saved = persistence.loadQueueState();
      expect(saved, isNotNull);
      expect(saved!.queue.single.neteaseId, 42);
      expect(saved.queue.single.title, '旧歌');
      // 需求：退出重进自动刷新播放 URL —— 过期直链不再复用
      expect(saved.queue.single.source, isEmpty);
      expect(saved.queue.single.needsUrlResolve, isTrue);
      expect(saved.hasNeteaseIds, isTrue);
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
      expect(h.map((QueueSnapshot s) => s.title).toList(),
          <String>['C', 'B', 'A']);

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

    test('快照记录继续播放位置（第十六批：历史播放「继续播放」）', () async {
      await persistence.pushHistory(
        'A',
        <Track>[track('a1'), track('a2'), track('a3')],
        currentIndex: 2,
      );
      final QueueSnapshot snap = persistence.loadHistory().single;
      expect(snap.currentIndex, 2);

      // 旧档无 currentIndex 字段 → 默认 0
      await prefs.setString(
          PrefsKeys.queueHistory, '[{"title":"B","tracks":[],"savedAt":123}]');
      expect(persistence.loadHistory().first.currentIndex, 0);

      // currentIndex 越界 → clamp 到曲目范围内
      await prefs.setString(PrefsKeys.queueHistory,
          '[{"title":"C","tracks":[],"savedAt":123,"currentIndex":99}]');
      expect(persistence.loadHistory().first.currentIndex, 0);
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
