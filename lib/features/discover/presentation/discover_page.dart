/// 发现页（App 首页）：Zephyr-Music 首页样式重构。
///
/// 顶部圆形快捷入口（需求）：每日推荐 / 私人漫游 / 私人雷达 / 心动模式 /
/// 雷达歌单 / 相似歌曲；
/// 下方板块（需求，从上到下）：个性推荐歌单 / 推荐新音乐 / 新歌速递 /
/// 热搜榜 / 榜单精选（支持跟 Zephyr 一样的自定义勾选，持久化）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../../core/widgets/sheet_host.dart';
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../data/netease_providers.dart';
import '../data/netease_repository.dart' show kToplists, ToplistConf;
import 'package:go_router/go_router.dart';

class DiscoverPage extends ConsumerWidget {
  const DiscoverPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            pinned: true,
            expandedHeight: 0,
            toolbarHeight: 64,
            backgroundColor: AppConstants.darkScaffold,
            titleSpacing: 20,
            title: const Text(
              '发现',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.search_rounded, size: 26),
                onPressed: () => context.push('/search'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          // 需求：顶部圆形快捷入口（Zephyr-Music 首页样式）
          const SliverToBoxAdapter(child: _QuickEntries()),
          const SliverToBoxAdapter(child: _PersonalizedSection()),
          const SliverToBoxAdapter(child: _SongRailSection.music()),
          const SliverToBoxAdapter(child: _SongRailSection.newSong()),
          const SliverToBoxAdapter(child: _HotWordsSection()),
          const SliverToBoxAdapter(child: _ToplistCustomSection()),
          // 需求：主骨架 extendBody（导航栏/Mini 条液态玻璃透出内容）——
          // 列表尾部按「导航栏 + Mini 条 + 安全区」留白，末尾卡片可滚出玻璃条
          const SliverToBoxAdapter(child: _BottomSpacer()),
        ],
      ),
    );
  }
}

/// 发现页尾部留白：导航栏 64 + 悬浮 Mini 条 70 + 缓冲 36 + 系统安全区。
class _BottomSpacer extends StatelessWidget {
  const _BottomSpacer();

  @override
  Widget build(BuildContext context) {
    final double safe = MediaQuery.paddingOf(context).bottom;
    return SizedBox(height: safe + 64 + 70 + 36);
  }
}

// ---------------------------------------------------------------- 快捷入口

/// 顶部个性化推荐类入口（需求：显示歌单封面，对齐 Zephyr-Music 推荐页 ——
/// 网易云样式圆角方块，有封面的入口直接用封面图）：
///  - 每日推荐：品牌红渐变方块 + 当日日期（网易云日历样式）；
///  - 私人漫游：蓝渐变 + 图标；
///  - 私人雷达：私人雷达歌单**封面**（轻量 /playlist/detail，失败回退图标）；
///  - 心动模式：粉渐变 + 图标；
///  - 雷达歌单：首个推荐歌单**封面**（/recommend/resource 首项，回退图标）；
///  - 相似歌曲：琥珀渐变 + 图标。
class _QuickEntries extends ConsumerWidget {
  const _QuickEntries();

  Future<void> _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    return Future<void>.value();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PlaylistMeta?> radar =
        ref.watch(personalRadarMetaProvider);
    final AsyncValue<List<PlaylistMeta>> daily =
        ref.watch(dailyPlaylistProvider);
    final String dayLabel = '${DateTime.now().day}';

    final List<({Widget visual, String label, VoidCallback onTap})> entries =
        <({Widget visual, String label, VoidCallback onTap})>[
      (
        visual: _QuickTile.date(dayLabel),
        label: '每日推荐',
        onTap: () => _openDaily(context, ref),
      ),
      (
        visual: const _QuickTile.icon(Icons.sensors_rounded, Color(0xFF2E7CF6)),
        label: '私人漫游',
        onTap: () => _openPersonalFm(context, ref),
      ),
      (
        visual: _QuickTile.cover(
          cover: radar.valueOrNull?.coverUrl,
          fallbackIcon: Icons.radar_rounded,
          fallbackColor: const Color(0xFF7B4DFF),
        ),
        label: '私人雷达',
        onTap: () => context
            .push('/toplist/3136952023?name=${Uri.encodeComponent('私人雷达')}'),
      ),
      (
        visual:
            const _QuickTile.icon(Icons.favorite_rounded, Color(0xFFFF6FA5)),
        label: '心动模式',
        onTap: () => _openHeartbeat(context, ref),
      ),
      (
        visual: _QuickTile.cover(
          cover: daily.valueOrNull?.firstOrNull?.coverUrl,
          fallbackIcon: Icons.travel_explore_rounded,
          fallbackColor: const Color(0xFF17B8A6),
        ),
        label: '雷达歌单',
        onTap: () => _openRadarPlaylists(context, ref),
      ),
      (
        visual:
            const _QuickTile.icon(Icons.graphic_eq_rounded, Color(0xFFF5A623)),
        label: '相似歌曲',
        onTap: () => _openSimilar(context, ref),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
      child: Row(
        children: <Widget>[
          for (final e in entries)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: e.onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: <Widget>[
                      e.visual,
                      const SizedBox(height: 6),
                      Text(
                        e.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _requireLogin(BuildContext context, WidgetRef ref) {
    _toast(context, '该功能需要登录后使用');
    showLoginSheet(context);
  }

  /// 每日推荐（需求：/recommend/songs → 入队播放全部）
  Future<void> _openDaily(BuildContext context, WidgetRef ref) async {
    if (!ref.read(authProvider).loggedIn) {
      _requireLogin(context, ref);
      return;
    }
    _toast(context, '正在获取每日推荐…');
    try {
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).recommendSongs();
      if (!context.mounted) return;
      if (songs.isEmpty) {
        _toast(context, '今日暂无推荐歌曲');
        return;
      }
      ref.read(playerProvider.notifier).playSongs(
        <Track>[for (final Song s in songs) s.toTrack()],
        queueTitle: '每日推荐',
      );
    } catch (_) {
      if (context.mounted) _toast(context, '获取每日推荐失败，请稍后重试');
    }
  }

  /// 私人漫游（需求：对齐 Zephyr-Music 的处理方式 —— 不再把
  /// /personal_fm 返回的 3 首当固定队列，改走 startPersonalFm()：
  /// isFm 队列在临近队尾时自动再拉一批追加，漫游不再只播三首）
  Future<void> _openPersonalFm(BuildContext context, WidgetRef ref) async {
    if (!ref.read(authProvider).loggedIn) {
      _requireLogin(context, ref);
      return;
    }
    _toast(context, '正在进入私人漫游…');
    final String? err =
        await ref.read(playerProvider.notifier).startPersonalFm();
    if (!context.mounted) return;
    if (err != null) _toast(context, err);
  }

  /// 心动模式（需求：/playmode/intelligence/list，基于当前播放歌曲）
  Future<void> _openHeartbeat(BuildContext context, WidgetRef ref) async {
    final Track? current = ref.read(playerProvider).currentTrack;
    final int? songId = current?.neteaseId;
    if (!ref.read(authProvider).loggedIn) {
      _requireLogin(context, ref);
      return;
    }
    if (songId == null || songId <= 0) {
      _toast(context, '先播放一首歌曲再开启心动模式');
      return;
    }
    _toast(context, '正在生成心动模式…');
    try {
      final List<Song> songs = await ref
          .read(neteaseRepositoryProvider)
          .intelligenceList(songId, 3136952023);
      if (!context.mounted) return;
      if (songs.isEmpty) {
        _toast(context, '心动模式暂无可用推荐');
        return;
      }
      ref.read(playerProvider.notifier).playSongs(
        <Track>[for (final Song s in songs) s.toTrack()],
        queueTitle: '心动模式',
      );
    } catch (_) {
      if (context.mounted) _toast(context, '心动模式获取失败，请稍后重试');
    }
  }

  /// 雷达歌单（需求：登录后 /recommend/resource 列表选择）
  Future<void> _openRadarPlaylists(BuildContext context, WidgetRef ref) async {
    if (!ref.read(authProvider).loggedIn) {
      _requireLogin(context, ref);
      return;
    }
    await showMingSheet<void>(
      context,
      isScrollControlled: true,
      barrierLabel: '雷达歌单',
      builder: (BuildContext ctx) => const _RadarPlaylistSheet(),
    );
  }

  /// 相似歌曲（需求：/simi/song 基于当前播放歌曲）
  Future<void> _openSimilar(BuildContext context, WidgetRef ref) async {
    final Track? current = ref.read(playerProvider).currentTrack;
    final int? songId = current?.neteaseId;
    if (songId == null || songId <= 0) {
      _toast(context, '先播放一首歌曲再找相似歌曲');
      return;
    }
    _toast(context, '正在查找相似歌曲…');
    try {
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).simiSongs(songId);
      if (!context.mounted) return;
      if (songs.isEmpty) {
        _toast(context, '暂无相似歌曲');
        return;
      }
      ref.read(playerProvider.notifier).playSongs(
        <Track>[for (final Song s in songs) s.toTrack()],
        queueTitle: '相似歌曲',
      );
    } catch (_) {
      if (context.mounted) _toast(context, '获取相似歌曲失败，请稍后重试');
    }
  }
}

/// 顶部入口圆角方块（46×46，radius 14；网易云推荐页样式）：
///  - date：品牌红渐变 + 当日日期数字（每日推荐专用）；
///  - icon：彩色渐变底 + 白图标（无封面入口）；
///  - cover：歌单封面图（封面加载失败回退 icon 形态）。
class _QuickTile extends StatelessWidget {
  const _QuickTile.icon(this.icon, this.color)
      : coverUrl = null,
        dayNumber = null;

  const _QuickTile.date(this.dayNumber)
      : icon = null,
        color = AppConstants.brandColor,
        coverUrl = null;

  const _QuickTile.cover({
    String? cover,
    required IconData fallbackIcon,
    required Color fallbackColor,
  })  : coverUrl = cover,
        icon = fallbackIcon,
        color = fallbackColor,
        dayNumber = null;

  final IconData? icon;
  final Color color;
  final String? coverUrl;
  final String? dayNumber;

  static const double _size = 46;

  @override
  Widget build(BuildContext context) {
    final String? cover = coverUrl;
    if (cover != null && cover.isNotEmpty) {
      return _frame(
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: CoverImage(src: cover, size: _size, radius: 14),
        ),
      );
    }
    final String? day = dayNumber;
    if (day != null) {
      // 每日推荐：网易云日历样式 —— 红渐变方块 + 白色日期数字
      return _frame(
        Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                color.withValues(alpha: 0.95),
                color.withValues(alpha: 0.72),
              ],
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            day,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
        ),
      );
    }
    return _frame(
      Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              color.withValues(alpha: 0.95),
              color.withValues(alpha: 0.65),
            ],
          ),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _frame(Widget child) {
    return SizedBox(width: _size, height: _size, child: child);
  }
}

/// 雷达歌单选择弹层（/recommend/resource → recommend[]）
class _RadarPlaylistSheet extends ConsumerWidget {
  const _RadarPlaylistSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<PlaylistMeta>> state =
        ref.watch(dailyPlaylistProvider);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: <Widget>[
                  const Text(
                    '雷达歌单',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white60, size: 22),
                  ),
                ],
              ),
            ),
            Expanded(
              child: state.when(
                loading: () => const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.6),
                  ),
                ),
                error: (Object e, StackTrace st) => Center(
                  child: Text(
                    '雷达歌单加载失败，请稍后重试',
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                  ),
                ),
                data: (List<PlaylistMeta> list) {
                  if (list.isEmpty) {
                    return Center(
                      child: Text('暂无雷达歌单',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5))),
                    );
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => Divider(
                        height: 1, color: Colors.white.withValues(alpha: 0.06)),
                    itemBuilder: (BuildContext ctx, int index) {
                      final PlaylistMeta p = list[index];
                      return ListTile(
                        dense: true,
                        leading:
                            CoverImage(src: p.coverUrl, size: 44, radius: 8),
                        title: Text(p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14)),
                        onTap: () {
                          Navigator.of(context).pop();
                          context.push(
                            '/playlist/${p.id}?name=${Uri.encodeComponent(p.name)}',
                            extra: p,
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 榜单精选（自定义）

/// 榜单精选（需求：跟 Zephyr-Music 一样的自定义 —— 右上「自定义」勾选榜单，
/// 顺序持久化；默认前 6 个）
class _ToplistCustomSection extends ConsumerWidget {
  const _ToplistCustomSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<int> ids = ref.watch(discoverToplistIdsProvider);
    final List<ToplistConf> selected = <ToplistConf>[
      for (final int id in ids)
        if (kToplists.any((ToplistConf t) => t.id == id))
          kToplists.firstWhere((ToplistConf t) => t.id == id),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
            child: Row(
              children: <Widget>[
                const Text('榜单精选',
                    style:
                        TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                const Spacer(),
                // 需求：榜单精选自定义（Zephyr 同款勾选）
                TextButton.icon(
                  onPressed: () => _showEditor(context, ref),
                  icon: const Icon(Icons.tune_rounded, size: 17),
                  label: const Text('自定义', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        Theme.of(context).colorScheme.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: selected.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (BuildContext context, int index) {
                final ToplistConf t = selected[index];
                return _ToplistCard(
                    id: t.id, name: t.name, color: Color(t.color));
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditor(BuildContext context, WidgetRef ref) async {
    final List<int> current =
        List<int>.of(ref.read(discoverToplistIdsProvider));
    final List<int>? result = await showMingSheet<List<int>>(
      context,
      isScrollControlled: true,
      barrierLabel: '榜单精选自定义',
      builder: (BuildContext ctx) => _ToplistEditorSheet(selected: current),
    );
    if (result != null) {
      ref.read(discoverToplistIdsProvider.notifier).setIds(result);
    }
  }
}

/// 榜单精选自定义编辑弹层（多选勾选，按勾选顺序展示）
class _ToplistEditorSheet extends StatefulWidget {
  const _ToplistEditorSheet({required this.selected});

  final List<int> selected;

  @override
  State<_ToplistEditorSheet> createState() => _ToplistEditorSheetState();
}

class _ToplistEditorSheetState extends State<_ToplistEditorSheet> {
  late final List<int> _ids;

  @override
  void initState() {
    super.initState();
    _ids = List<int>.of(widget.selected);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.66,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: <Widget>[
                  const Text(
                    '榜单精选自定义',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_ids),
                    child: const Text('完成',
                        style: TextStyle(
                            color: AppConstants.brandColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '勾选要展示的榜单（按勾选顺序排列，可多选）',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11.5),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: <Widget>[
                  for (final ToplistConf t in kToplists)
                    CheckboxListTile(
                      dense: true,
                      value: _ids.contains(t.id),
                      activeColor: AppConstants.brandColor,
                      controlAffinity: ListTileControlAffinity.trailing,
                      secondary: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              Color(t.color).withValues(alpha: 0.95),
                              Color(t.color),
                            ],
                          ),
                        ),
                        alignment: Alignment.center,
                        child: _rankLabel(t),
                      ),
                      title: Text(
                        t.name,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      onChanged: (bool? v) {
                        setState(() {
                          if (v == true) {
                            _ids.add(t.id);
                          } else {
                            _ids.remove(t.id);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rankLabel(ToplistConf t) {
    final String head = t.name.isNotEmpty ? t.name.characters.first : '榜';
    return Text(
      head,
      style: const TextStyle(
          color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
    );
  }
}

// ---------------------------------------------------------------- 榜单卡片

class _ToplistCard extends StatelessWidget {
  const _ToplistCard({
    required this.id,
    required this.name,
    required this.color,
  });

  final int id;
  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () =>
          context.push('/toplist/$id?name=${Uri.encodeComponent(name)}'),
      child: Container(
        width: 140,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[color.withValues(alpha: 0.95), color],
          ),
        ),
        child: Stack(
          children: <Widget>[
            Positioned(
              right: 10,
              bottom: 10,
              child: Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: Colors.white24,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 推荐歌单

/// 个性推荐歌单（需求：对齐 Zephyr-Music 推荐页顶部样式 —— 方形圆角封面、
/// 播放量角标在左上、标题两行下方，三卡屏宽可见）
class _PersonalizedSection extends ConsumerWidget {
  const _PersonalizedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<PlaylistMeta>> state =
        ref.watch(personalizedProvider);
    return state.when(
      loading: () => const _SectionLoading(),
      error: (Object e, StackTrace st) => _SectionError(
        message: '推荐歌单加载失败',
        onRetry: () => ref.invalidate(personalizedProvider),
      ),
      data: (List<PlaylistMeta> list) {
        if (list.isEmpty) {
          return const _SectionError(
            message: '暂无推荐内容',
            onRetry: null,
          );
        }
        return _SectionScaffold(
          title: '个性推荐歌单',
          child: SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (BuildContext context, int index) =>
                  _PlaylistCard(meta: list[index]),
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.meta});

  final PlaylistMeta meta;

  String _playCountText() {
    final int? count = meta.playCount;
    if (count == null) return '';
    if (count >= 100000000) {
      return '${(count / 100000000).toStringAsFixed(1)}亿';
    }
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)}万';
    }
    return '$count';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GestureDetector(
      onTap: () => context.push(
        '/playlist/${meta.id}?name=${Uri.encodeComponent(meta.name)}',
        extra: meta,
      ),
      child: SizedBox(
        width: 118,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Stack(
              children: <Widget>[
                CoverImage(
                  src: meta.coverUrl,
                  size: 118,
                  radius: 8,
                ),
                // Zephyr/网易云样式：播放量角标左上（播放图标 + 万/亿计数）
                Positioned(
                  top: 5,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 12),
                        Text(
                          _playCountText(),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              meta.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 推荐新音乐 / 新歌速递

/// 横向歌曲卡板块（推荐新音乐 / 新歌速递 共用骨架，需求：Zephyr 首页板块）
class _SongRailSection extends ConsumerWidget {
  const _SongRailSection.music() : _kind = _RailKind.music;

  const _SongRailSection.newSong() : _kind = _RailKind.newSong;

  final _RailKind _kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String title = _kind == _RailKind.music ? '推荐新音乐' : '新歌速递';
    final AsyncValue<List<Song>> state = _kind == _RailKind.music
        ? ref.watch(personalizedNewSongsProvider)
        : ref.watch(topNewSongsProvider);

    return state.when(
      loading: () => const _SectionLoading(),
      error: (Object e, StackTrace st) => _SectionError(
        message: '$title加载失败',
        onRetry: () {
          if (_kind == _RailKind.music) {
            ref.invalidate(personalizedNewSongsProvider);
          } else {
            ref.invalidate(topNewSongsProvider);
          }
        },
      ),
      data: (List<Song> list) {
        if (list.isEmpty) {
          return _SectionError(
            message: '$title暂无内容',
            onRetry: () {
              if (_kind == _RailKind.music) {
                ref.invalidate(personalizedNewSongsProvider);
              } else {
                ref.invalidate(topNewSongsProvider);
              }
            },
          );
        }
        return _SectionScaffold(
          title: title,
          child: SizedBox(
            height: 172,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (BuildContext context, int index) =>
                  _SongRailCard(songs: list, index: index, title: title),
            ),
          ),
        );
      },
    );
  }
}

enum _RailKind { music, newSong }

/// 横向歌曲卡：方形圆角封面 + 歌名/歌手；点击整组入队从该首播放
class _SongRailCard extends ConsumerWidget {
  const _SongRailCard({
    required this.songs,
    required this.index,
    required this.title,
  });

  final List<Song> songs;
  final int index;
  final String title;

  void _play(BuildContext context, WidgetRef ref) {
    ref.read(playerProvider.notifier).playSongs(
      <Track>[for (final Song s in songs) s.toTrack()],
      startIndex: index,
      queueTitle: title,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Song s = songs[index];
    final ThemeData theme = Theme.of(context);
    return GestureDetector(
      onTap: () => _play(context, ref),
      child: SizedBox(
        width: 118,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CoverImage(src: s.coverUrl, size: 118, radius: 10),
            const SizedBox(height: 6),
            Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 12.5,
              ),
            ),
            Text(
              s.artists,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 热搜

class _HotWordsSection extends ConsumerWidget {
  const _HotWordsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<HotWord>> state = ref.watch(hotWordsProvider);
    return state.when(
      loading: () => const SizedBox.shrink(),
      error: (Object e, StackTrace st) => const SizedBox.shrink(),
      data: (List<HotWord> words) {
        if (words.isEmpty) return const SizedBox.shrink();
        return _SectionScaffold(
          title: '热搜榜',
          topPadding: 26,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                for (int i = 0; i < words.length && i < 12; i++)
                  ActionChip(
                    label: Text(
                      words[i].word,
                      style: TextStyle(
                        fontSize: 13,
                        color: i < 3
                            ? AppConstants.brandColor
                            : Theme.of(context).colorScheme.onSurface,
                        fontWeight: i < 3 ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    side: BorderSide.none,
                    onPressed: () => context.push(
                        '/search?kw=${Uri.encodeComponent(words[i].word)}'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 通用

/// 板块骨架：标题行（可选顶部间距）+ 内容
class _SectionScaffold extends StatelessWidget {
  const _SectionScaffold({
    required this.title,
    required this.child,
    this.topPadding = 8,
  });

  final String title;
  final Widget child;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SectionHeader(title: title),
          child,
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.chevron_right_rounded, size: 22),
        ],
      ),
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
      ),
    );
  }
}

class _SectionError extends StatelessWidget {
  const _SectionError({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      child: Column(
        children: <Widget>[
          Icon(Icons.cloud_off_rounded,
              size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(message,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }
}
