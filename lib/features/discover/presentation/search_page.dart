/// 搜索页（需求重构，参考用户发送的搜索页截图）：
///
///  - 搜索历史：本地持久化（最多 20 条，去重置顶），头部垃圾桶一键清空；
///  - 猜你喜欢：基于热搜词的补充推荐 chips；
///  - 热榜矩阵：热搜榜 + 热歌榜/欧美热歌榜/古风榜/飙升榜/韩语榜/新歌榜/
///    说唱榜/原创榜/民谣榜/日语榜/ACG 榜/摇滚榜 —— 横向滑动双列卡片，
///    每列展示前 10 名（前三名高亮，热搜前三带「爆」标）；
///  - 搜索建议（/search/suggest，250ms 防抖）+ 结果整页可作队列播放。
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
  SearchSuggest? _suggest;

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
    // 搜索建议（实时，250ms 防抖，对齐 Zephyr useSearchSuggest）
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final SearchSuggest s = await ref
            .read(neteaseRepositoryProvider)
            .searchSuggest(value.trim());
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: _SearchTypeBar(current: _searchType, onSelect: _switchType),
        ),
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
      padding: const EdgeInsets.symmetric(vertical: 6),
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
      padding: const EdgeInsets.symmetric(vertical: 6),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
      padding: const EdgeInsets.symmetric(vertical: 8),
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
      padding: const EdgeInsets.symmetric(vertical: 6),
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
      padding: const EdgeInsets.only(top: 2, bottom: 24),
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
class _SearchHome extends ConsumerWidget {
  const _SearchHome({required this.onWord});

  /// 词点击 → 原页直接搜索
  final ValueChanged<String> onWord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<String> history = ref.watch(searchHistoryProvider);
    final AsyncValue<List<HotWord>> hot = ref.watch(hotWordsProvider);

    return ListView(
      padding: const EdgeInsets.only(top: 6, bottom: 24),
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
              runSpacing: 10,
              children: <Widget>[
                for (final String kw in history)
                  ActionChip(
                    label: Text(kw, style: const TextStyle(fontSize: 13)),
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    side: BorderSide.none,
                    onPressed: () => onWord(kw),
                  ),
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
                          onPressed: () => onWord(w.word),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
          orElse: () => const SizedBox.shrink(),
        ),

        // ---------------- 热榜矩阵（需求：热搜榜 + 12 榜单） ----------------
        const _HeaderRow(title: '热榜'),
        _HotChartRail(onWord: onWord),
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

/// 热榜矩阵（需求：热搜榜 + 热歌榜/欧美热歌榜/古风榜/飙升榜/韩语榜/新歌榜/
/// 说唱榜/原创榜/民谣榜/日语榜/ACG 榜/摇滚榜）—— 横向滑动双列卡片，
/// 每列前 10 名；热搜词条点击搜索，榜单歌曲点击直接播放。
class _HotChartRail extends ConsumerWidget {
  const _HotChartRail({this.onWord});

  final ValueChanged<String>? onWord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 470,
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

/// 热搜榜列（需求：前三名带「爆」标，点击词条搜索）
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
          return Column(
            children: <Widget>[
              for (int i = 0; i < words.length && i < 10; i++)
                _ChartRow(
                  rank: i + 1,
                  text: words[i].word,
                  badge: i == 0 ? '爆' : null,
                  onTap: () => onWord?.call(words[i].word),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 榜单列（/playlist/track/all 前 10 行；点击行直接播放该曲）
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
    return _ChartCard(
      title: name,
      color: color,
      onTapHeader: () =>
          context.push('/toplist/$id?name=${Uri.encodeComponent(name)}'),
      child: state.when(
        loading: () => const _ColumnLoading(),
        error: (Object e, StackTrace st) => const _ColumnMessage('加载失败'),
        data: (List<Song> songs) {
          if (songs.isEmpty) return const _ColumnMessage('暂无内容');
          return Column(
            children: <Widget>[
              for (int i = 0; i < songs.length && i < 10; i++)
                _ChartRow(
                  rank: i + 1,
                  text: songs[i].name,
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

/// 双列榜单卡片容器
class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.color,
    required this.child,
    this.onTapHeader,
  });

  final String title;
  final Color color;
  final Widget child;
  final VoidCallback? onTapHeader;

  @override
  Widget build(BuildContext context) {
    final double width =
        (MediaQuery.sizeOf(context).width - 20 * 2 - 12) / 2.05;
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
                          fontSize: 14.5, fontWeight: FontWeight.w700),
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

/// 榜单行（前三名彩色名次；热搜第一名「爆」标）
class _ChartRow extends StatelessWidget {
  const _ChartRow({
    required this.rank,
    required this.text,
    this.badge,
    this.onTap,
  });

  final int rank;
  final String text;
  final String? badge;
  final VoidCallback? onTap;

  Color get _rankColor => switch (rank) {
        1 => const Color(0xFFE2483D),
        2 => const Color(0xFFFF8A3D),
        3 => const Color(0xFFF5A623),
        _ => Colors.white38,
      };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 22,
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: rank <= 3 ? FontWeight.w800 : FontWeight.w500,
                  color: _rankColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: rank <= 3 ? FontWeight.w600 : FontWeight.w400,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: rank <= 3 ? 0.96 : 0.78),
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

// ---------------------------------------------------------------- 搜索建议

class _SuggestList extends StatelessWidget {
  const _SuggestList({required this.suggest, required this.onTap});

  final SearchSuggest suggest;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final List<String> keywords = <String>[
      ...suggest.keywords,
      ...suggest.artists.map((String a) => a),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: <Widget>[
        for (final String kw in keywords)
          ListTile(
            leading: const Icon(Icons.search_rounded, size: 20),
            title: Text(kw,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5)),
            dense: true,
            onTap: () => onTap(kw),
          ),
      ],
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
