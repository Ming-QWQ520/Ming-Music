/// 搜索页（需求重构，参考用户发送的搜索页截图）：
///
///  - 搜索历史：本地持久化（最多 20 条，去重置顶），头部垃圾桶一键清空；
///  - 猜你喜欢：基于热搜词的补充推荐 chips；
///  - 热榜矩阵（第十七批：top20 + 官方截图同款卡片）：热搜榜 + 热歌榜/
///    欧美热歌榜/古风榜/飙升榜/韩语榜/新歌榜/说唱榜/原创榜/民谣榜/
///    日语榜/ACG 榜/摇滚榜 —— 横向滑动卡片（单卡 ~84% 屏宽，下一卡
///    右缘露出），卡头「▶ 播放」一键播整榜，行 = 前三名彩色名次 + 歌名
///    + 灰色歌手后缀 + 爆标/上升箭头，每卡渲染前 20 名（超高内部滚动）；
///  - 搜索联想词（第十七批：POST /search/suggest/keyword/get，三层兜底
///    落到旧 /search/suggest；直 hit 歌曲卡 + 高亮分段 + 标签 + 相关搜索，
///    250ms 防抖）+ 结果整页可作队列播放。
///  - 第十四批需求（对齐 Zephyr-Music WIP）：分类筛选搜索 —— 综合/单曲/
///    歌单/专辑/歌手/MV/用户/歌词 八类（/search type 全量），综合按
///    result.order 分区块展示、区块头点击跳转对应分类。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/storage/prefs_keys.dart';
import '../../../core/widgets/cover_image.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/add_to_playlist_sheet.dart';
import '../../player/providers/player_providers.dart';
import '../../settings/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import '../data/netease_providers.dart';
import '../data/netease_repository.dart' show kToplists, ToplistConf;
import 'widgets/song_actions_sheet.dart';
import 'widgets/song_tile.dart';

// ---------------------------------------------------------------- 搜索历史

/// 搜索历史（需求：本地持久化，最多 20 条，新词置顶去重）
final NotifierProvider<SearchHistoryNotifier, List<String>>
    searchHistoryProvider =
    NotifierProvider<SearchHistoryNotifier, List<String>>(
        SearchHistoryNotifier.new);

class SearchHistoryNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final String? raw =
        ref.watch(sharedPreferencesProvider).getString(PrefsKeys.searchHistory);
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List<Object?>) {
          return decoded
              .whereType<String>()
              .where((String s) => s.isNotEmpty)
              .toList();
        }
      } catch (_) {
        // 脏数据 → 空
      }
    }
    return const <String>[];
  }

  void _persist() {
    ref
        .read(sharedPreferencesProvider)
        .setString(PrefsKeys.searchHistory, jsonEncode(state));
  }

  void add(String keyword) {
    final String kw = keyword.trim();
    if (kw.isEmpty) return;
    final List<String> next = <String>[
      kw,
      ...state.where((String s) => s != kw)
    ];
    state = next.length > 20 ? next.sublist(0, 20) : next;
    _persist();
  }

  void remove(String keyword) {
    state = state.where((String s) => s != keyword).toList();
    _persist();
  }

  void clear() {
    state = const <String>[];
    _persist();
  }
}

// ---------------------------------------------------------------- 分类筛选

/// 搜索分类（第十四批需求，对齐 Zephyr-Music WIP 分支）：
/// type 值与网易云官方一致 —— 1018 综合 / 1 单曲 / 1000 歌单 / 10 专辑 /
/// 100 歌手 / 1004 MV / 1002 用户 / 1006 歌词
const List<(int, String)> kSearchTypes = <(int, String)>[
  (1018, '综合'),
  (1, '单曲'),
  (1000, '歌单'),
  (10, '专辑'),
  (100, '歌手'),
  (1004, 'MV'),
  (1002, '用户'),
  (1006, '歌词'),
];

// ---------------------------------------------------------------- 页面

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialKeyword});

  final String? initialKeyword;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  Timer? _debounce;

  /// 分类搜索结果（当前 type 对应的列表非空，其余空）
  SearchResults? _bundle;
  bool _searching = false;
  String? _error;
  bool _showResults = false;

  /// 联想词下拉（第十七批：新接口 /search/suggest/keyword/get，
  /// 含直 hit 歌曲卡/高亮分段/标签/相关搜索）
  KeywordSuggest? _suggest;

  /// 当前搜索分类（默认综合，对齐网易云 App）
  int _searchType = 1018;

  /// 切换分类：有结果时立即以新分类重搜（对齐 Zephyr WIP
  /// `searchType = t.value; if (keyword) runSearch(keyword)`）
  void _switchType(int type) {
    if (type == _searchType) return;
    setState(() => _searchType = type);
    final String kw = _controller.text.trim();
    if (_showResults && kw.isNotEmpty) {
      _doSearch(kw);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialKeyword ?? '');
    _focus = FocusNode();
    if ((widget.initialKeyword ?? '').isNotEmpty) {
      _doSearch(widget.initialKeyword!);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _showResults = false;
        _suggest = null;
      });
      return;
    }
    // 搜索联想词（实时，250ms 防抖；新接口三层兜底，
    // 进程内记忆命中路径后直达）
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final KeywordSuggest s = await ref
            .read(neteaseRepositoryProvider)
            .searchKeywordSuggest(value.trim());
        if (!mounted || value.trim() != _controller.text.trim()) return;
        setState(() => _suggest = s);
      } catch (_) {
        if (mounted) setState(() => _suggest = null);
      }
    });
  }

  Future<void> _doSearch(String keywords) async {
    if (keywords.isEmpty) return;
    _focus.unfocus();
    // 需求：搜索历史 —— 发起搜索即记录（新词置顶去重）
    ref.read(searchHistoryProvider.notifier).add(keywords);
    setState(() {
      _searching = true;
      _showResults = true;
      _error = null;
      _suggest = null;
    });
    try {
      final SearchResults bundle = await ref
          .read(neteaseRepositoryProvider)
          .searchByType(keywords, _searchType);
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败，请稍后重试（$e）';
        _searching = false;
      });
    }
  }

  /// 当前分类的单曲结果（单曲/歌词/综合区块用）
  List<Song> get _songs => _bundle?.songs ?? const <Song>[];

  void _playAt(int index, {List<Song>? from}) {
    final List<Song> pool = from ?? _songs;
    if (index < 0 || index >= pool.length) return;
    final List<Track> tracks =
        pool.map((Song s) => s.toTrack()).toList(growable: false);
    ref.read(playerProvider.notifier).playSongs(
          tracks,
          startIndex: index,
          queueTitle: '搜索：${_controller.text.trim()}',
        );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: widget.initialKeyword == null,
          onChanged: _onChanged,
          onSubmitted: (String v) => _doSearch(v.trim()),
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: '搜索歌曲、歌手、专辑、MV、用户',
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.6),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(Icons.search_rounded, size: 21),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 19),
                    onPressed: () {
                      _controller.clear();
                      setState(() {
                        _showResults = false;
                        _suggest = null;
                      });
                      _focus.requestFocus();
                    },
                  ),
          ),
        ),
        // 第十四批需求：分类筛选条（综合/单曲/歌单/专辑/歌手/MV/用户/歌词）
        // 需求：筛选条只在搜索后的结果页显示 —— 未搜索时
        //（历史/联想/热榜首页）不占高度
        bottom: _showResults
            ? PreferredSize(
                preferredSize: const Size.fromHeight(46),
                child: _SearchTypeBar(current: _searchType, onSelect: _switchType),
              )
            : null,
      ),
      body: !_showResults
          ? (_suggest != null && !_suggest!.isEmpty
              ? _SuggestList(
                  suggest: _suggest!,
                  onTap: (String kw) {
                    _controller.text = kw;
                    _doSearch(kw);
                  },
                )
              : _SearchHome(onWord: _doSearch))
          : _buildResults(theme),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_searching) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
      );
    }
    if (_error != null) {
      return _MessagePanel(
        icon: Icons.cloud_off_rounded,
        message: _error!,
        action: _controller.text.trim().isEmpty
            ? null
            : () => _doSearch(_controller.text.trim()),
      );
    }
    final SearchResults? bundle = _bundle;
    if (bundle == null || bundle.isEmpty) {
      return const _MessagePanel(
          icon: Icons.search_off_rounded, message: '没有找到相关内容');
    }
    // 第十四批需求：按分类渲染
    switch (_searchType) {
      case 1000:
        return _PlaylistResults(bundle.playlists);
      case 10:
        return _AlbumResults(bundle.albums);
      case 100:
        return _ArtistResults(bundle.artists);
      case 1004:
        return _MvResults(bundle.mvs);
      case 1002:
        return _UserResults(bundle.users);
      case 1018:
        return _CompositeResults(
          bundle: bundle,
          onMore: _switchType,
          onPlayAt: (int i, List<Song> pool) => _playAt(i, from: pool),
        );
      default: // 1 单曲 / 1006 歌词
        return _SongResults(
          songs: bundle.songs,
          onPlayAt: (int i) => _playAt(i),
        );
    }
  }

  /// 单曲结果列表（单曲/歌词分类共用；综合页的单曲区块复用行组件，
  /// 行构建见顶层 _songRow）
}

/// 单曲行构建（单曲/歌词/综合共用；withSwipe 仅独立单曲分类开启 ——
/// 左滑 = 添加至歌单；右滑 = 下一首播放，与歌单详情页同规则）
Widget _songRow(
  BuildContext context,
  WidgetRef ref, {
  required Song s,
  required int index,
  required List<Song> pool,
  required VoidCallback onPlay,
  bool withSwipe = false,
}) {
  final Widget tile = SongTile(
    song: s,
    onPlay: onPlay,
    onMore: () => showSongActionsSheet(context, s.toTrack()),
    onLongPress: () => showSongActionsSheet(context, s.toTrack()),
  );
  if (!withSwipe) return tile;
  return Dismissible(
    key: ValueKey<String>('search_${s.id}_$index'),
    confirmDismiss: (DismissDirection dir) async {
      if (dir == DismissDirection.startToEnd) {
        final String? err =
            await ref.read(playerProvider.notifier).insertNext(s.toTrack());
        if (!context.mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(err ?? '已添加至下一首播放：${s.name}'),
        ));
      } else {
        await showAddToPlaylistSheet(context, ref, <int>[s.id]);
      }
      return false; // 动作后回弹，不移除行
    },
    background: _SearchSwipeBg(
      color: AppConstants.brandColor,
      icon: Icons.low_priority_rounded,
      label: '下一首播放',
      alignRight: false,
    ),
    secondaryBackground: _SearchSwipeBg(
      color: const Color(0xFF3D7BFF),
      icon: Icons.playlist_add_rounded,
      label: '添加到歌单',
      alignRight: true,
    ),
    child: tile,
  );
}

// ---------------------------------------------------------------- 分类渲染

/// 播放量格式化（1.2万 / 340）
String _formatCount(int n) {
  if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
  return '$n';
}

/// 分类筛选条（第十四批需求）：横向滑动 chips，选中态品牌色填充
class _SearchTypeBar extends StatelessWidget {
  const _SearchTypeBar({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        itemCount: kSearchTypes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final (int type, String label) = kSearchTypes[index];
          final bool selected = type == current;
          return Material(
            color: selected
                ? AppConstants.brandColor
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => onSelect(type),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected
                          ? Colors.white
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 单曲/歌词分类结果（与旧版行为一致：滑动快捷操作 + 整页可作队列）
class _SongResults extends ConsumerWidget {
  const _SongResults({required this.songs, required this.onPlayAt});

  final List<Song> songs;
  final ValueChanged<int> onPlayAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      // 第十六批：底部留白防 Mini 条遮挡末尾行（单曲/歌词分类共用）
      padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 96),
      itemCount: songs.length,
      itemBuilder: (BuildContext context, int index) {
        final Song s = songs[index];
        return _songRow(
          context,
          ref,
          s: s,
          index: index,
          pool: songs,
          onPlay: () => onPlayAt(index),
          withSwipe: true,
        );
      },
    );
  }
}

/// 歌单分类结果（封面行 → /playlist/:id）
class _PlaylistResults extends StatelessWidget {
  const _PlaylistResults(this.playlists);

  final List<PlaylistMeta> playlists;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // 第十六批：底部留白防 Mini 条遮挡末尾行
      padding: EdgeInsets.only(
          top: 6, bottom: MediaQuery.paddingOf(context).bottom + 96),
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) {
        final PlaylistMeta p = playlists[index];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CoverImage(src: p.coverUrl, size: 52, radius: 8),
          ),
          title: Text(p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${p.creator ?? '未知创建者'} · ${_formatCount(p.playCount ?? 0)}次播放'
              '${p.trackCount != null ? ' · ${p.trackCount}首' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          onTap: () => context.push('/playlist/${p.id}'),
        );
      },
    );
  }
}

/// 专辑分类结果（方封面行 → /album/:id）
class _AlbumResults extends StatelessWidget {
  const _AlbumResults(this.albums);

  final List<SearchAlbum> albums;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // 第十六批：底部留白防 Mini 条遮挡末尾行
      padding: EdgeInsets.only(
          top: 6, bottom: MediaQuery.paddingOf(context).bottom + 96),
      itemCount: albums.length,
      itemBuilder: (BuildContext context, int index) {
        final SearchAlbum a = albums[index];
        final String? year = a.publishTime == null || a.publishTime! <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(a.publishTime!)
                .year
                .toString();
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CoverImage(src: a.picUrl, size: 52, radius: 8),
          ),
          title: Text(a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              <String>[
                a.artist,
                if (a.songCount != null) '${a.songCount}首',
                if (year != null) year,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          onTap: () => context
              .push('/album/${a.id}?name=${Uri.encodeComponent(a.name)}'),
        );
      },
    );
  }
}

/// 歌手分类结果（3 列圆形头像网格 → /artist/:id）
class _ArtistResults extends StatelessWidget {
  const _ArtistResults(this.artists);

  final List<SearchArtist> artists;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      // 第十六批：底部留白防 Mini 条遮挡末尾行
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, MediaQuery.paddingOf(context).bottom + 96),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.86,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
      ),
      itemCount: artists.length,
      itemBuilder: (BuildContext context, int index) {
        final SearchArtist a = artists[index];
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context
              .push('/artist/${a.id}?name=${Uri.encodeComponent(a.name)}'),
          child: Column(
            children: <Widget>[
              CoverImage(src: a.picUrl, size: 92, radius: 46),
              const SizedBox(height: 7),
              Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              if (a.alias.isNotEmpty)
                Text(
                  a.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// MV 分类结果（16:9 封面行 → /mv/:id）
class _MvResults extends StatelessWidget {
  const _MvResults(this.mvs);

  final List<SearchMv> mvs;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // 第十六批：底部留白防 Mini 条遮挡末尾行
      padding: EdgeInsets.only(
          top: 8, bottom: MediaQuery.paddingOf(context).bottom + 96),
      itemCount: mvs.length,
      itemBuilder: (BuildContext context, int index) {
        final SearchMv m = mvs[index];
        return InkWell(
          onTap: () =>
              context.push('/mv/${m.id}?title=${Uri.encodeComponent(m.name)}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 124,
                  height: 70,
                  child: Stack(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child:
                            CoverImage(src: m.coverUrl, size: 124, radius: 9),
                      ),
                      const Positioned.fill(
                        child: Center(
                          child: Icon(Icons.play_circle_fill_rounded,
                              size: 30, color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(m.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        <String>[
                          if (m.artistName.isNotEmpty) m.artistName,
                          if (m.playCount != null)
                            '${_formatCount(m.playCount!)}次播放',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 用户分类结果（头像行；暂无用户主页路由，仅展示）
class _UserResults extends StatelessWidget {
  const _UserResults(this.users);

  final List<SearchUser> users;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // 第十六批：底部留白防 Mini 条遮挡末尾行
      padding: EdgeInsets.only(
          top: 6, bottom: MediaQuery.paddingOf(context).bottom + 96),
      itemCount: users.length,
      itemBuilder: (BuildContext context, int index) {
        final SearchUser u = users[index];
        return ListTile(
          leading: CoverImage(src: u.avatarUrl, size: 44, radius: 22),
          title: Text(u.nickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5)),
          subtitle: u.signature.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(u.signature,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
        );
      },
    );
  }
}

/// 综合搜索结果（第十四批需求）：按 result.order 分区块展示，
/// 每区块限流展示，区块头「更多」跳转对应分类
class _CompositeResults extends ConsumerWidget {
  const _CompositeResults({
    required this.bundle,
    required this.onMore,
    required this.onPlayAt,
  });

  final SearchResults bundle;
  final ValueChanged<int> onMore;
  final void Function(int index, List<Song> pool) onPlayAt;

  /// 各区块限流（与网易云 App 观感一致：综合页每类少量 + 更多入口）
  static const int _kSongs = 5;
  static const int _kOthers = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> sections = <Widget>[];

    for (final String key in bundle.order) {
      switch (key) {
        case 'song':
          if (bundle.songs.isEmpty) break;
          final List<Song> pool =
              bundle.songs.take(_kSongs).toList(growable: false);
          sections.add(_SectionHeader(title: '单曲', onMore: () => onMore(1)));
          for (int i = 0; i < pool.length; i++) {
            sections.add(_songRow(
              context,
              ref,
              s: pool[i],
              index: i,
              pool: pool,
              onPlay: () => onPlayAt(i, pool),
            ));
          }
        case 'playList':
          if (bundle.playlists.isEmpty) break;
          sections.add(_SectionHeader(title: '歌单', onMore: () => onMore(1000)));
          for (final PlaylistMeta p in bundle.playlists.take(_kOthers)) {
            sections.add(ListTile(
              dense: true,
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: CoverImage(src: p.coverUrl, size: 44, radius: 7),
              ),
              title: Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(
                '${p.creator ?? ''} · ${_formatCount(p.playCount ?? 0)}次播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant),
              ),
              onTap: () => context.push('/playlist/${p.id}'),
            ));
          }
        case 'artist':
          if (bundle.artists.isEmpty) break;
          sections.add(_SectionHeader(title: '歌手', onMore: () => onMore(100)));
          final List<SearchArtist> list =
              bundle.artists.take(6).toList(growable: false);
          sections.add(SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 18),
              itemBuilder: (BuildContext context, int index) {
                final SearchArtist a = list[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push(
                      '/artist/${a.id}?name=${Uri.encodeComponent(a.name)}'),
                  child: SizedBox(
                    width: 64,
                    child: Column(
                      children: <Widget>[
                        CoverImage(src: a.picUrl, size: 64, radius: 32),
                        const SizedBox(height: 5),
                        Text(a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ));
        case 'album':
          if (bundle.albums.isEmpty) break;
          sections.add(_SectionHeader(title: '专辑', onMore: () => onMore(10)));
          for (final SearchAlbum a in bundle.albums.take(_kOthers)) {
            sections.add(ListTile(
              dense: true,
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: CoverImage(src: a.picUrl, size: 44, radius: 7),
              ),
              title: Text(a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(a.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurfaceVariant)),
              onTap: () => context
                  .push('/album/${a.id}?name=${Uri.encodeComponent(a.name)}'),
            ));
          }
        case 'mv':
          if (bundle.mvs.isEmpty) break;
          sections.add(_SectionHeader(title: 'MV', onMore: () => onMore(1004)));
          for (final SearchMv m in bundle.mvs.take(_kOthers)) {
            sections.add(ListTile(
              dense: true,
              leading: SizedBox(
                width: 76,
                height: 44,
                child: Stack(
                  children: <Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CoverImage(src: m.coverUrl, size: 76, radius: 6),
                    ),
                    const Positioned.fill(
                      child: Center(
                        child: Icon(Icons.play_circle_fill_rounded,
                            size: 22, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
              title: Text(m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(
                <String>[
                  if (m.artistName.isNotEmpty) m.artistName,
                  if (m.playCount != null) '${_formatCount(m.playCount!)}次播放',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant),
              ),
              onTap: () => context
                  .push('/mv/${m.id}?title=${Uri.encodeComponent(m.name)}'),
            ));
          }
        case 'user':
          if (bundle.users.isEmpty) break;
          sections.add(_SectionHeader(title: '用户', onMore: () => onMore(1002)));
          for (final SearchUser u in bundle.users.take(_kOthers)) {
            sections.add(ListTile(
              dense: true,
              leading: CoverImage(src: u.avatarUrl, size: 38, radius: 19),
              title: Text(u.nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
              subtitle: u.signature.isEmpty
                  ? null
                  : Text(u.signature,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurfaceVariant)),
            ));
          }
        default:
          break; // sim_query / voice / new_mlog 等未知区块不展示
      }
    }

    if (sections.isEmpty) {
      return const _MessagePanel(
          icon: Icons.search_off_rounded, message: '没有找到相关内容');
    }
    return ListView(
      padding: EdgeInsets.only(
          top: 2, bottom: MediaQuery.paddingOf(context).bottom + 96),
      children: sections,
    );
  }
}

/// 综合页区块头：标题 + 尾部「更多」入口
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onMore});

  final String title;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 4),
      child: Row(
        children: <Widget>[
          Text(title,
              style:
                  const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
          const Spacer(),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
            ),
            onPressed: onMore,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('更多',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const Icon(Icons.chevron_right_rounded, size: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 搜索首页

/// 空态首页（需求）：搜索历史 + 猜你喜欢 + 热榜矩阵
///
/// 需求：长按搜索历史词条 1s 弹出 X，点击 X 删除该条记录 ——
/// 词条状态化管理（长按 1s 后该 chip 右上角浮出删除角标）。
class _SearchHome extends ConsumerStatefulWidget {
  const _SearchHome({required this.onWord});

  /// 词点击 → 原页直接搜索
  final ValueChanged<String> onWord;

  @override
  ConsumerState<_SearchHome> createState() => _SearchHomeState();
}

class _SearchHomeState extends ConsumerState<_SearchHome> {
  /// 当前处于「待删除」编辑态的历史词条（null = 无）
  String? _editingKw;

  /// 1s 长按计时器（onLongPressStart 后 500ms 手势层才判定长按，
  /// 这里从长按判定时刻起再计 1s，松手取消）
  Timer? _lpTimer;

  @override
  void dispose() {
    _lpTimer?.cancel();
    super.dispose();
  }

  Widget _historyChip(String kw) {
    final bool editing = _editingKw == kw;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (LongPressStartDetails _) {
            _lpTimer?.cancel();
            _lpTimer = Timer(const Duration(seconds: 1), () {
              if (mounted) setState(() => _editingKw = kw);
            });
          },
          onLongPressEnd: (LongPressEndDetails _) => _lpTimer?.cancel(),
          onLongPressCancel: () => _lpTimer?.cancel(),
          child: ActionChip(
            label: Text(kw, style: const TextStyle(fontSize: 13)),
            backgroundColor: editing
                ? AppConstants.brandColor.withValues(alpha: 0.14)
                : Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5),
            side: BorderSide.none,
            // 编辑态下点词条本体 = 退出编辑态（防误触跳转）
            onPressed: editing
                ? () => setState(() => _editingKw = null)
                : () => widget.onWord(kw),
          ),
        ),
        if (editing)
          Positioned(
            right: -5,
            top: -5,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                ref.read(searchHistoryProvider.notifier).remove(kw);
                if (mounted) setState(() => _editingKw = null);
              },
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: AppConstants.brandColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: const Icon(Icons.close_rounded,
                    size: 13, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> history = ref.watch(searchHistoryProvider);
    final AsyncValue<List<HotWord>> hot = ref.watch(hotWordsProvider);

    return ListView(
      padding: EdgeInsets.only(
          top: 6, bottom: MediaQuery.paddingOf(context).bottom + 96),
      children: <Widget>[
        // ---------------- 搜索历史（需求） ----------------
        if (history.isNotEmpty)
          _HeaderRow(
            title: '搜索历史',
            trailing: IconButton(
              tooltip: '清空历史',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline_rounded,
                  size: 19,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              onPressed: () async {
                final bool? ok = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext ctx) => AlertDialog(
                    title: const Text('清空搜索历史'),
                    content: const Text('确定清空全部搜索历史吗？'),
                    actions: <Widget>[
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('取消')),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: AppConstants.brandColor),
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  ref.read(searchHistoryProvider.notifier).clear();
                }
              },
            ),
          ),
        if (history.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Wrap(
              spacing: 10,
              runSpacing: 14,
              children: <Widget>[
                for (final String kw in history) _historyChip(kw),
              ],
            ),
          ),

        // ---------------- 猜你喜欢（需求） ----------------
        hot.maybeWhen(
          data: (List<HotWord> words) {
            if (words.length < 8) return const SizedBox.shrink();
            final List<HotWord> guess =
                words.sublist(6, words.length < 14 ? words.length : 12);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _HeaderRow(title: '猜你喜欢'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: <Widget>[
                      for (final HotWord w in guess)
                        ActionChip(
                          label: Text(w.word,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.35),
                          side: BorderSide.none,
                          onPressed: () => widget.onWord(w.word),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
          orElse: () => const SizedBox.shrink(),
        ),

        // ---------------- 热榜矩阵（第十七批：top20 + 官方图同款卡片） ----------------
        const _HeaderRow(title: '热榜'),
        _HotChartRail(onWord: widget.onWord),
      ],
    );
  }
}

/// 板块标题行（可带尾部动作）
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        children: <Widget>[
          Text(title,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 热榜矩阵

/// 热榜矩阵（第十七批需求：搜索页面底部的榜单只渲染前二十的歌曲，
/// 布局对齐官方 App 截图）——
///  - 横向滑动卡片，单卡占屏宽 ~84%，下一张卡右缘露出（截图同款）；
///  - 卡头：色条 + 榜名 + 「▶ 播放」胶囊（歌曲榜，点其一键播整榜）；
///  - 行：前三名彩色名次（红/橙/金）+ 歌名白色 + 灰色歌手后缀；
///    热搜榜第 1 名「爆」标，官方 iconType==1 行右侧红色 ↑ 上升箭头；
///  - 每卡渲染前 20 名，卡内容超高时内部纵向滚动（与官方一致）。
/// 热搜词条点击搜索，榜单歌曲点击直接播放。
class _HotChartRail extends ConsumerWidget {
  const _HotChartRail({this.onWord});

  final ValueChanged<String>? onWord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 卡高：小屏至少 520，大屏至多 780，其余随屏幕余量伸缩
    final double height =
        (MediaQuery.sizeOf(context).height - 300).clamp(520.0, 780.0);
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: kToplists.length + 1, // 第 0 列 = 热搜榜
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return _HotSearchColumn(onWord: onWord);
          }
          final ToplistConf t = kToplists[index - 1];
          return _ChartColumn(
            id: t.id,
            name: t.name,
            color: Color(t.color),
          );
        },
      ),
    );
  }
}

/// 热搜榜卡（前 20 名；第 1 名「爆」标，iconType==1 红色上升箭头，
/// 点击词条搜索）
class _HotSearchColumn extends ConsumerWidget {
  const _HotSearchColumn({this.onWord});

  final ValueChanged<String>? onWord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<HotWord>> state = ref.watch(hotWordsProvider);
    return _ChartCard(
      title: '热搜榜',
      color: AppConstants.brandColor,
      onTapHeader: () {
        final List<HotWord>? words = state.value;
        if (words != null && words.isNotEmpty && onWord != null) {
          onWord!(words.first.word);
        }
      },
      child: state.when(
        loading: () => const _ColumnLoading(),
        error: (Object e, StackTrace st) => const _ColumnMessage('热搜加载失败'),
        data: (List<HotWord> words) {
          if (words.isEmpty) return const _ColumnMessage('暂无热搜');
          return ListView(
            padding: const EdgeInsets.only(bottom: 6),
            children: <Widget>[
              for (int i = 0;
                  i < words.length && i < _kChartRowCount;
                  i++)
                _ChartRow(
                  rank: i + 1,
                  text: words[i].word,
                  badge: i == 0 ? '爆' : null,
                  rising: words[i].iconType == 1,
                  onTap: () => onWord?.call(words[i].word),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 榜单卡（/playlist/track/all 前 20 行；点击行直接播放该曲，
/// 卡头「播放」一键播整榜）
class _ChartColumn extends ConsumerWidget {
  const _ChartColumn({
    required this.id,
    required this.name,
    required this.color,
  });

  final int id;
  final String name;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Song>> state = ref.watch(toplistPreviewProvider(id));
    final List<Song> songs = state.value ?? const <Song>[];
    return _ChartCard(
      title: name,
      color: color,
      onTapHeader: () =>
          context.push('/toplist/$id?name=${Uri.encodeComponent(name)}'),
      onPlay: songs.isEmpty
          ? null
          : () {
              ref.read(playerProvider.notifier).playSongs(
                    <Track>[for (final Song s in songs) s.toTrack()],
                    queueTitle: name,
                  );
            },
      child: state.when(
        loading: () => const _ColumnLoading(),
        error: (Object e, StackTrace st) => const _ColumnMessage('加载失败'),
        data: (List<Song> songs) {
          if (songs.isEmpty) return const _ColumnMessage('暂无内容');
          return ListView(
            padding: const EdgeInsets.only(bottom: 6),
            children: <Widget>[
              for (int i = 0;
                  i < songs.length && i < _kChartRowCount;
                  i++)
                _ChartRow(
                  rank: i + 1,
                  text: songs[i].name,
                  subText: songs[i].artists,
                  onTap: () {
                    ref.read(playerProvider.notifier).playSongs(
                      <Track>[for (final Song s in songs) s.toTrack()],
                      startIndex: i,
                      queueTitle: name,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 每卡渲染行数（第十七批需求：只渲染前二十的歌曲）
const int _kChartRowCount = 20;

/// 榜单卡片容器（官方 App 截图同款：单卡 ~84% 屏宽，圆角 16，
/// 卡头「榜单名 + ▶播放胶囊」，卡身可内部纵向滚动看完整 20 行）
class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.color,
    required this.child,
    this.onTapHeader,
    this.onPlay,
  });

  final String title;
  final Color color;
  final Widget child;
  final VoidCallback? onTapHeader;

  /// 「▶ 播放」胶囊回调（热搜榜不展示胶囊）
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final double width =
        (MediaQuery.sizeOf(context).width - 20 * 2 - 12) * 0.84;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            onTap: onTapHeader,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 5,
                    height: 16,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w800),
                    ),
                  ),
                  // 「▶ 播放」胶囊（截图同款：灰底圆胶囊，一键播整榜）
                  if (onPlay != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: onPlay,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(Icons.play_arrow_rounded,
                                  size: 15,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.85)),
                              const SizedBox(width: 3),
                              Text(
                                '播放',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.85)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const Icon(Icons.chevron_right_rounded,
                      size: 17, color: Colors.white38),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 榜单行（前三名彩色名次：红/橙/金；歌名 + 灰色歌手后缀；
/// 「爆」标/红色上升箭头右对齐）
class _ChartRow extends StatelessWidget {
  const _ChartRow({
    required this.rank,
    required this.text,
    this.subText,
    this.badge,
    this.rising = false,
    this.onTap,
  });

  final int rank;
  final String text;

  /// 灰色后缀（歌曲榜 = 歌手名；热搜榜无）
  final String? subText;
  final String? badge;

  /// 红色 ↑ 上升箭头（热搜榜官方 iconType==1）
  final bool rising;
  final VoidCallback? onTap;

  Color get _rankColor => switch (rank) {
        1 => const Color(0xFFE2483D),
        2 => const Color(0xFFFF8A3D),
        3 => const Color(0xFFF5A623),
        _ => Colors.white38,
      };

  @override
  Widget build(BuildContext context) {
    // 第十五批需求：榜单卡为 16 圆角容器，行涟漪带圆角防溢出卡片底部圆角
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 22,
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: rank <= 3 ? FontWeight.w800 : FontWeight.w500,
                  color: _rankColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: DefaultTextStyle.of(context).style,
                  children: <InlineSpan>[
                    TextSpan(
                      text: text,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight:
                            rank <= 3 ? FontWeight.w700 : FontWeight.w400,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: rank <= 3 ? 0.96 : 0.80),
                      ),
                    ),
                    if (subText != null && subText!.isNotEmpty) ...<InlineSpan>[
                      const WidgetSpan(
                          child: SizedBox(width: 6)),
                      TextSpan(
                        text: subText,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.38),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (badge != null) ...<Widget>[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppConstants.brandColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ] else if (rising) ...<Widget>[
              const SizedBox(width: 6),
              const Icon(Icons.north_rounded,
                  size: 14, color: AppConstants.brandColor),
            ],
          ],
        ),
      ),
    );
  }
}

class _ColumnLoading extends StatelessWidget {
  const _ColumnLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      ),
    );
  }
}

class _ColumnMessage extends StatelessWidget {
  const _ColumnMessage(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 搜索联想

/// 搜索联想下拉（第十七批需求，对齐官方 App 搜索框下拉）：
///  - 第 0 条直 hit 歌曲卡：封面 + 歌名 + 歌手 + 「原唱」标签，点击**直接播放**；
///  - 联想词列表：highLightInfo 高亮分段（highLighted 段着品牌红，即官方
///    App 的红色前缀），带「热搜」等标签，点击搜索该词；
///  - 相关搜索（data.recTitle + recs）：同联想词行渲染。
class _SuggestList extends ConsumerWidget {
  const _SuggestList({required this.suggest, required this.onTap});

  final KeywordSuggest suggest;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final List<SuggestWord> words = suggest.words;
    final bool hasCards =
        suggest.songs.isNotEmpty || suggest.artists.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: <Widget>[
        // ---- 歌曲/歌手卡片（需求修复：联想词未显示歌曲或歌手卡片 ——
        // 线上 mobile 联想接口无 entity_card，卡片由并行结构化搜索生成） ----
        for (final Song s in suggest.songs)
          _SuggestSongCard(
            song: s,
            onPlay: () {
              ref.read(playerProvider.notifier).playSongs(
                    <Track>[s.toTrack()],
                    queueTitle: '搜索直达：${s.name}',
                  );
            },
          ),
        for (final SearchArtist a in suggest.artists)
          _SuggestArtistCard(artist: a),
        if (hasCards) const Divider(height: 10, indent: 16, endIndent: 16),
        // ---- 直 hit 歌曲卡（entity_card，点击直接播放整首） ----
        if (suggest.directHit != null && suggest.directHit!.directHit != null)
          _DirectHitCard(
            song: suggest.directHit!.directHit!,
            onPlay: () {
              final Song s = suggest.directHit!.directHit!;
              ref.read(playerProvider.notifier).playSongs(
                    <Track>[s.toTrack()],
                    queueTitle: '搜索直达：${s.name}',
                  );
            },
          ),
        // ---- 联想词 ----
        for (final SuggestWord w in words)
          _SuggestWordRow(
            word: w,
            onTap: () => onTap(w.keyword),
          ),
        // ---- 相关搜索 ----
        if (suggest.recs.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              suggest.recTitle,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final String kw in suggest.recs)
            _SuggestWordRow(
              word: SuggestWord(keyword: kw),
              onTap: () => onTap(kw),
            ),
        ],
      ],
    );
  }
}

/// 直 hit 歌曲卡（联想下拉顶部，点击直接播放）
class _DirectHitCard extends StatelessWidget {
  const _DirectHitCard({required this.song, required this.onPlay});

  final Song song;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CoverImage(src: song.coverUrl, size: 52, radius: 8),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artists} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppConstants.brandColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.play_arrow_rounded,
                      size: 16, color: AppConstants.brandColor),
                  Text('播放',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppConstants.brandColor)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 联想下拉歌曲卡（需求修复：联想词未显示歌曲/歌手卡片 ——
/// 点击直接播放该曲，VIP 歌曲带徽标）
class _SuggestSongCard extends StatelessWidget {
  const _SuggestSongCard({required this.song, required this.onPlay});

  final Song song;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: CoverImage(src: song.coverUrl, size: 46, radius: 7),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (song.isVipOnly) ...<Widget>[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppConstants.brandColor,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            'VIP',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artists} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.play_circle_fill_rounded,
                size: 26, color: AppConstants.brandColor),
          ],
        ),
      ),
    );
  }
}

/// 联想下拉歌手卡（圆形头像 + 歌手标签，点击进入歌手页）
class _SuggestArtistCard extends StatelessWidget {
  const _SuggestArtistCard({required this.artist});

  final SearchArtist artist;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: () => context
          .push('/artist/${artist.id}?name=${Uri.encodeComponent(artist.name)}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
        child: Row(
          children: <Widget>[
            CoverImage(src: artist.picUrl, size: 44, radius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                  if (artist.alias.isNotEmpty)
                    Text(
                      artist.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppConstants.brandColor.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                '歌手',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppConstants.brandColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条联想词行（高亮分段 + 标签）
class _SuggestWordRow extends StatelessWidget {
  const _SuggestWordRow({required this.word, required this.onTap});

  final SuggestWord word;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 高亮分段：highLighted 段着品牌红（官方红色前缀），否则按常规文字
    final List<InlineSpan> spans = <InlineSpan>[
      for (final seg in word.segments)
        TextSpan(
          text: seg.text,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight:
                seg.highlighted ? FontWeight.w600 : FontWeight.w400,
            color: seg.highlighted
                ? AppConstants.brandColor
                : theme.colorScheme.onSurface,
          ),
        ),
      // 无分段数据（旧接口兜底）：整词常规渲染
      if (word.segments.isEmpty)
        TextSpan(
          text: word.keyword,
          style: TextStyle(
              fontSize: 14.5, color: theme.colorScheme.onSurface),
        ),
    ];
    return ListTile(
      leading: const Icon(Icons.search_rounded, size: 20),
      title: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(children: spans, style: DefaultTextStyle.of(context).style),
      ),
      dense: true,
      trailing: word.tag == null
          ? null
          : Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppConstants.brandColor.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                word.tag!,
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppConstants.brandColor),
              ),
            ),
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------- 滑动背景

/// 搜索页滑动背景提示（与歌单详情页 _SwipeBg 同款样式）
class _SearchSwipeBg extends StatelessWidget {
  const _SearchSwipeBg({
    required this.color,
    required this.icon,
    required this.label,
    required this.alignRight,
  });

  final Color color;
  final IconData icon;
  final String label;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (alignRight) ...<Widget>[
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
          ],
          Icon(icon, color: Colors.white, size: 20),
          if (!alignRight) ...<Widget>[
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 44, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: action, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}
