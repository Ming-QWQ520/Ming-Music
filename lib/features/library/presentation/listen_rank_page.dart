/// 听歌排行榜（/user/record：最近一周 / 所有时间，带播放次数计分）。
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

class ListenRankPage extends ConsumerStatefulWidget {
  const ListenRankPage({super.key});

  @override
  ConsumerState<ListenRankPage> createState() => _ListenRankPageState();
}

class _ListenRankPageState extends ConsumerState<ListenRankPage> {
  bool _week = true;
  List<PlayRecordSong>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return;
    setState(() {
      _error = null;
      _items = null;
    });
    try {
      final List<PlayRecordSong> items = await ref
          .read(neteaseRepositoryProvider)
          .userRecord(auth.profile!.userId, week: _week);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('听歌排行')),
      body: !auth.loggedIn
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.leaderboard_rounded,
                      size: 48, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text('登录后可查看听歌排行'),
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
          : Column(
              children: <Widget>[
                // 周榜/总榜切换（仿网易云胶囊）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: <Widget>[
                      _RangeChip(
                        label: '最近一周',
                        active: _week,
                        onTap: () {
                          if (_week) return;
                          setState(() => _week = true);
                          _load();
                        },
                      ),
                      const SizedBox(width: 10),
                      _RangeChip(
                        label: '所有时间',
                        active: !_week,
                        onTap: () {
                          if (!_week) return;
                          setState(() => _week = false);
                          _load();
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildBody()),
              ],
            ),
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
          '暂无听歌数据',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final PlayRecordSong r = items[index];
        final Song s = r.song;
        return SongTile(
          song: s,
          trackIndex: index + 1,
          onPlay: () => ref.read(playerProvider.notifier).playSongs(
            <Track>[for (final PlayRecordSong x in items) x.song.toTrack()],
            startIndex: index,
            queueTitle: _week ? '听歌排行 · 最近一周' : '听歌排行 · 所有时间',
          ),
          onMore: () => showSongActionsSheet(context, s.toTrack()),
          onLongPress: () => showSongActionsSheet(context, s.toTrack()),
          trailing: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              '${r.score}次',
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? AppConstants.brandColor.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            color: active
                ? AppConstants.brandColor
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
