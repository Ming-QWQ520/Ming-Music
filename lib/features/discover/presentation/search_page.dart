/// 搜索页（需求重构，参考用户发送的搜索页截图）：
///
///  - 搜索历史：本地持久化（最多 20 条，去重置顶），头部垃圾桶一键清空；
///  - 猜你喜欢：基于热搜词的补充推荐 chips；
///  - 热榜矩阵：热搜榜 + 热歌榜/欧美热歌榜/古风榜/飙升榜/韩语榜/新歌榜/
///    说唱榜/原创榜/民谣榜/日语榜/ACG 榜/摇滚榜 —— 横向滑动双列卡片，
///    每列展示前 10 名（前三名高亮，热搜前三带「爆」标）；
///  - 搜索建议（/search/suggest，250ms 防抖）+ 结果整页可作队列播放。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/storage/prefs_keys.dart';
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
    final String? raw = ref
        .watch(sharedPreferencesProvider)
        .getString(PrefsKeys.searchHistory);
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List<Object?>) {
          return decoded.whereType<String>().where((String s) => s.isNotEmpty).toList();
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
    final List<String> next = <String>[kw, ...state.where((String s) => s != kw)];
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
  List<Song> _results = <Song>[];
  bool _searching = false;
  String? _error;
  bool _showResults = false;
  SearchSuggest? _suggest;

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
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).search(keywords);
      if (!mounted) return;
      setState(() {
        _results = songs;
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

  void _playAt(int index) {
    final List<Track> tracks =
        _results.map((Song s) => s.toTrack()).toList(growable: false);
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
            hintText: '搜索歌曲、歌手、专辑',
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
    if (_results.isEmpty) {
      return const _MessagePanel(
          icon: Icons.search_off_rounded, message: '没有找到相关歌曲');
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (BuildContext context, int index) {
        final Song s = _results[index];
        // 需求调整：滑动方向对调 —— 左滑 = 添加至歌单；右滑 = 下一首播放
        // （与歌单详情页同规则）
        return Dismissible(
          key: ValueKey<String>('search_${s.id}'),
          confirmDismiss: (DismissDirection dir) async {
            if (dir == DismissDirection.startToEnd) {
              final String? err = await ref
                  .read(playerProvider.notifier)
                  .insertNext(s.toTrack());
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
          child: SongTile(
            song: s,
            onPlay: () => _playAt(index),
            onMore: () => showSongActionsSheet(context, s.toTrack()),
            onLongPress: () => showSongActionsSheet(context, s.toTrack()),
          ),
        );
      },
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
                    label: Text(kw,
                        style: const TextStyle(fontSize: 13)),
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
            final List<HotWord> guess = words.sublist(6, words.length < 14 ? words.length : 12);
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
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700)),
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
        error: (Object e, StackTrace st) =>
            const _ColumnMessage('热搜加载失败'),
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
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
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
                  fontWeight:
                      rank <= 3 ? FontWeight.w800 : FontWeight.w500,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
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
