/// 最近播放（/record/recent/song，需登录）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart';
import '../../discover/data/netease_providers.dart';
import '../../discover/presentation/widgets/song_actions_sheet.dart';
import '../../discover/presentation/widgets/song_tile.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';

class RecentSongsPage extends ConsumerStatefulWidget {
  const RecentSongsPage({super.key});

  @override
  ConsumerState<RecentSongsPage> createState() => _RecentSongsPageState();
}

class _RecentSongsPageState extends ConsumerState<RecentSongsPage> {
  List<PlayRecordSong>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _items = null;
    });
    try {
      final List<PlayRecordSong> items =
          await ref.read(neteaseRepositoryProvider).recentSongs(limit: 100);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  List<Track> _asTracks() => <Track>[
        for (final PlayRecordSong r in _items ?? const <PlayRecordSong>[])
          r.song.toTrack(),
      ];

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('最近播放')),
      body: !auth.loggedIn
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.history_rounded,
                      size: 48, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text('登录后可查看最近播放'),
                  const SizedBox(height: 14),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppConstants.brandColor,
                    ),
                    onPressed: () => showLoginSheet(context),
                    child: const Text('去登录'),
                  ),
                ],
              ),
            )
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text('加载失败：$_error',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final List<PlayRecordSong>? items = _items;
    if (items == null) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
      );
    }
    if (items.isEmpty) {
      return Center(
        child: Text(
          '暂无最近播放记录',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 17,
                  backgroundColor: AppConstants.brandColor,
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 10),
                Text('播放全部 (${items.length})',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (BuildContext context, int index) {
            final Song s = items[index].song;
            return SongTile(
              song: s,
              onPlay: () => ref.read(playerProvider.notifier).playSongs(
                    _asTracks(),
                    startIndex: index,
                    queueTitle: '最近播放',
                  ),
              onMore: () => showSongActionsSheet(context, s.toTrack()),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}
