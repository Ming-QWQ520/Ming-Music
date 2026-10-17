/// 搜索页：热搜榜 + 关键词搜索，结果整页可作队列播放。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../data/netease_providers.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import 'widgets/song_tile.dart';

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
      setState(() => _showResults = false);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _doSearch(value.trim());
    });
  }

  Future<void> _doSearch(String keywords) async {
    setState(() {
      _searching = true;
      _showResults = true;
      _error = null;
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
        _error = '搜索失败，请稍后重试';
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
                      setState(() => _showResults = false);
                      _focus.requestFocus();
                    },
                  ),
          ),
        ),
      ),
      body: !_showResults ? const _HotList() : _buildResults(theme),
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
      itemBuilder: (BuildContext context, int index) => SongTile(
        song: _results[index],
        onPlay: () => _playAt(index),
      ),
    );
  }
}

// ---------------------------------------------------------------- 热搜榜

class _HotList extends ConsumerWidget {
  const _HotList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<HotWord>> state = ref.watch(hotWordsProvider);
    return state.when(
      loading: () => const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
      ),
      error: (Object e, StackTrace st) => _MessagePanel(
        icon: Icons.cloud_off_rounded,
        message: '热搜加载失败',
        action: () => ref.invalidate(hotWordsProvider),
      ),
      data: (List<HotWord> words) {
        if (words.isEmpty) {
          return const _MessagePanel(
              icon: Icons.local_fire_department_rounded, message: '暂无热搜');
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: words.length,
          separatorBuilder: (_, __) => const SizedBox(height: 0),
          itemBuilder: (BuildContext context, int index) {
            final HotWord word = words[index];
            final bool top3 = index < 3;
            return InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (BuildContext context) => SearchPage(
                  initialKeyword: word.word,
                ),
              )),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 30,
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: top3 ? FontWeight.w800 : FontWeight.w500,
                          color: top3
                              ? AppConstants.brandColor
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        word.word,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: top3 ? FontWeight.w600 : FontWeight.w400,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (top3)
                      const Icon(
                        Icons.local_fire_department_rounded,
                        color: AppConstants.brandColor,
                        size: 18,
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
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
          Text(message,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          if (action != null) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: action, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}
