/// 全局路由表（go_router）：
///
///  - `/`                    主骨架（发现 / 我的 Tab，IndexedStack 保状态）；
///  - `/search?kw=`          搜索页（热搜 + 建议 + 结果）；
///  - `/playlist/:id`        歌单详情（extra 传 PlaylistMeta 加速首帧）；
///  - `/toplist/:id?name=`   排行榜详情（同构歌单）；
///  - `/album/:id?name=`     专辑歌曲列表；
///  - `/artist/:id?name=`    歌手热门歌曲；
///  - `/settings`            设置页；
///  - `/player`              全屏播放页（上滑转场 + Hero 封面联动）；
///  - `/wiki/:songId`        歌曲百科（query: title/artist/mv）；
///  - `/mv/:id?title=`       MV 播放页；
///  - `/comments`            评论页（extra 传 Track）；
///  - `/liked-songs`         喜欢的歌曲（服务器红心）；
///  - `/local-music`         本地音乐；
///  - `/cloud-drive`         音乐云盘；
///  - `/recent-songs`        最近播放；
///  - `/listen-rank`         听歌排行榜；
///  - `/profile`             个人主页（Zephyr 对齐）；
///  - `/listen`              一起听（实验性 Beta，局域网同步）。
///
/// 通知栏点击 / Mini 播放条统一经 `openFullPlayer` 跳 `/player`，
/// 全屏播放页使用 CustomTransitionPage（上滑进入 + 淡入），
/// PageRoute 语义保证 Hero 动画正常驱动。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'api/netease_models.dart';
import '../features/comments/presentation/comments_page.dart';
import '../features/comments/providers/comments_providers.dart'
    show CommentsSubject;
import '../features/discover/presentation/album_songs_page.dart';
import '../features/discover/presentation/artist_songs_page.dart';
import '../features/discover/presentation/playlist_detail_page.dart';
import '../features/discover/presentation/search_page.dart';
import '../features/discover/presentation/song_wiki_page.dart';
import '../features/discover/presentation/mv_player_page.dart';
import '../features/library/domain/track.dart';
import '../features/library/presentation/liked_songs_page.dart';
import '../features/library/presentation/cloud_drive_page.dart';
import '../features/library/presentation/local_music_page.dart';
import '../features/library/presentation/recent_songs_page.dart';
import '../features/library/presentation/listen_rank_page.dart';
import '../features/library/presentation/profile_page.dart';
import '../features/listen/presentation/listen_together_page.dart';
import '../features/player/presentation/full_player_page.dart';
import '../features/settings/presentation/settings_page.dart';
import '../features/shell/presentation/main_scaffold.dart';

/// 全局导航钥匙（通知栏点击等无 context 场景使用）
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/',
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      name: 'home',
      pageBuilder: (BuildContext context, GoRouterState state) =>
          const NoTransitionPage<void>(child: MainScaffold()),
      routes: <RouteBase>[
        GoRoute(
          path: 'search',
          name: 'search',
          builder: (BuildContext context, GoRouterState state) => SearchPage(
            initialKeyword: state.uri.queryParameters['kw'],
          ),
        ),
        GoRoute(
          path: 'playlist/:id',
          name: 'playlist',
          builder: (BuildContext context, GoRouterState state) {
            final int id = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
            final Object? extra = state.extra;
            return PlaylistDetailPage.playlist(
              meta: extra is PlaylistMeta
                  ? extra
                  : PlaylistMeta(
                      id: id,
                      name: state.uri.queryParameters['name'] ?? '歌单',
                    ),
            );
          },
        ),
        GoRoute(
          path: 'toplist/:id',
          name: 'toplist',
          builder: (BuildContext context, GoRouterState state) {
            final int id = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
            return PlaylistDetailPage.toplist(
              id: id,
              name: state.uri.queryParameters['name'] ?? '排行榜',
            );
          },
        ),
        GoRoute(
          path: 'album/:id',
          name: 'album',
          builder: (BuildContext context, GoRouterState state) {
            final int id = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
            return AlbumSongsPage(
              albumId: id,
              name: state.uri.queryParameters['name'] ?? '专辑',
            );
          },
        ),
        GoRoute(
          path: 'artist/:id',
          name: 'artist',
          builder: (BuildContext context, GoRouterState state) {
            final int id = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
            return ArtistSongsPage(
              artistId: id,
              artistName: state.uri.queryParameters['name'] ?? '歌手',
            );
          },
        ),
        GoRoute(
          path: 'settings',
          name: 'settings',
          builder: (BuildContext context, GoRouterState state) =>
              const SettingsPage(),
        ),
        GoRoute(
          path: 'wiki/:songId',
          name: 'wiki',
          builder: (BuildContext context, GoRouterState state) {
            final int songId =
                int.tryParse(state.pathParameters['songId'] ?? '') ?? 0;
            final int? mvId =
                int.tryParse(state.uri.queryParameters['mv'] ?? '');
            return SongWikiPage(
              songId: songId,
              title: state.uri.queryParameters['title'] ?? '歌曲百科',
              artist: state.uri.queryParameters['artist'] ?? '',
              mvId: (mvId != null && mvId > 0) ? mvId : null,
            );
          },
        ),
        GoRoute(
          path: 'mv/:id',
          name: 'mv',
          builder: (BuildContext context, GoRouterState state) {
            final int id = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
            return MvPlayerPage(
              mvId: id,
              fallbackTitle: state.uri.queryParameters['title'] ?? 'MV',
            );
          },
        ),
        GoRoute(
          path: 'comments',
          name: 'comments',
          builder: (BuildContext context, GoRouterState state) {
            final Object? extra = state.extra;
            if (extra is CommentsSubject) return CommentsPage(subject: extra);
            final Track? track = extra is Track ? extra : null;
            final int? songId = track?.neteaseId;
            return CommentsPage(
              subject: CommentsSubject(
                id: (songId != null && songId > 0) ? songId : 0,
                track: track,
              ),
            );
          },
        ),
        GoRoute(
          path: 'liked-songs',
          name: 'liked-songs',
          builder: (BuildContext context, GoRouterState state) =>
              const LikedSongsPage(),
        ),
        GoRoute(
          path: 'local-music',
          name: 'local-music',
          builder: (BuildContext context, GoRouterState state) =>
              const LocalMusicPage(),
        ),
        GoRoute(
          path: 'cloud-drive',
          name: 'cloud-drive',
          builder: (BuildContext context, GoRouterState state) =>
              const CloudDrivePage(),
        ),
        GoRoute(
          path: 'recent-songs',
          name: 'recent-songs',
          builder: (BuildContext context, GoRouterState state) =>
              const RecentSongsPage(),
        ),
        GoRoute(
          path: 'listen-rank',
          name: 'listen-rank',
          builder: (BuildContext context, GoRouterState state) =>
              const ListenRankPage(),
        ),
        GoRoute(
          path: 'profile',
          name: 'profile',
          builder: (BuildContext context, GoRouterState state) =>
              const ProfilePage(),
        ),
        GoRoute(
          path: 'listen',
          name: 'listen-together',
          builder: (BuildContext context, GoRouterState state) =>
              const ListenTogetherPage(),
        ),
      ],
    ),
    // 全屏播放页：上滑转场 + Hero 封面联动（opaque=false 时封面从
    // 底部 Mini 条无缝放大，背景模糊随入场动画渐进）
    GoRoute(
      path: '/player',
      name: 'player',
      pageBuilder: (BuildContext context, GoRouterState state) =>
          CustomTransitionPage<void>(
        key: state.pageKey,
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        opaque: false,
        barrierColor: Colors.black54,
        transitionsBuilder: (BuildContext context, Animation<double> animation,
            Animation<double> secondaryAnimation, Widget child) {
          final Animation<double> curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(
              opacity: Tween<double>(begin: 0.4, end: 1).animate(curved),
              child: child,
            ),
          );
        },
        child: const FullPlayerPage(),
      ),
    ),
  ],
);

/// 打开全屏播放页（Mini 播放条 / 通知栏点击统一入口）。
///
/// 崩溃修复（logcat 实证 `GoRouter.of` 空指针）：全局 Mini 条经由
/// `MaterialApp.builder` 构建，其 context 位于 Router **之外**，
/// `GoRouter.of(context)` 在该上下文必抛
/// `Null check operator used on a null value`。
/// 因此统一走全局 [appRouter] 实例（不依赖 context 查找）；
/// 参数保留以兼容既有调用点。
Future<void> openFullPlayer(BuildContext context) {
  return appRouter.push<void>('/player');
}
