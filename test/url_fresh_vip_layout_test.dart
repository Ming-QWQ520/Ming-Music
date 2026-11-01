/// 403 直链根治与 UI 调整单元测试：
///  1. SongTile VIP 徽章紧贴歌手名称左侧（副标题行行首，歌手文本在后）；
///  2. EqBars 均衡器条纹动效组件渲染（播放/暂停两态均不抛错）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ming_music/core/api/netease_models.dart';
import 'package:ming_music/features/discover/presentation/widgets/song_tile.dart';
import 'package:ming_music/features/player/presentation/widgets/eq_bars.dart';

Song _vipSong() => const Song(
      id: 1901371647,
      name: '测试歌曲',
      artists: '测试歌手',
      album: '测试专辑',
      fee: 1, // fee == 1 → isVipOnly
    );

Song _freeSong() => const Song(
      id: 123,
      name: '免费歌曲',
      artists: '免费歌手',
      album: '',
    );

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('SongTile VIP 徽章位置（歌手名称左侧）', () {
    testWidgets('VIP 歌曲徽章出现在歌手文本之前', (WidgetTester tester) async {
      await tester.pumpWidget(_host(SongTile(song: _vipSong())));
      await tester.pump();

      // 徽章存在，且与歌手文本同处一个 Row（副标题行）
      final Finder badge = find.byType(VipBadge);
      expect(badge, findsOneWidget);
      final Row subtitleRow =
          tester.firstWidget<Row>(find.ancestor(of: badge, matching: find.byType(Row)).first);
      final int badgeIdx =
          subtitleRow.children.indexWhere((Widget w) => w is Opacity);
      final int artistIdx =
          subtitleRow.children.indexWhere((Widget w) => w is Expanded);
      expect(badgeIdx, greaterThanOrEqualTo(0),
          reason: '徽章（Opacity 包裹）应在副标题行内');
      expect(artistIdx, greaterThan(badgeIdx),
          reason: '歌手文本（Expanded）必须在徽章之后（徽章居左）');
    });

    testWidgets('非 VIP 歌曲不渲染徽章', (WidgetTester tester) async {
      await tester.pumpWidget(_host(SongTile(song: _freeSong())));
      await tester.pump();
      expect(find.byType(VipBadge), findsNothing);
    });
  });

  group('EqBars 均衡器条纹（歌单详情与播放列表共用动效）', () {
    testWidgets('暂停态渲染三根条纹且不抛错', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const EqBars(playing: false)));
      await tester.pump();
      final Finder paints = find.descendant(
          of: find.byType(EqBars), matching: find.byType(CustomPaint));
      expect(paints, findsOneWidget);
      expect(
          tester.widget<CustomPaint>(paints).painter, isNotNull,
          reason: '条纹画笔应已挂载');
    });

    testWidgets('播放态启动动画并可正常销毁', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const EqBars(playing: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(EqBars), findsOneWidget);
      await tester.pumpWidget(_host(const SizedBox.shrink()));
      await tester.pump();
    });
  });
}
