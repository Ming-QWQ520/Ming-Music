/// 音乐库主页：正在播放卡片 + 全部曲目列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/presentation/widgets/mini_player.dart' show openFullPlayer;
import '../../player/providers/player_providers.dart';
import '../domain/track.dart';
import '../providers/library_providers.dart';
import 'add_network_sheet.dart';
import 'track_tile.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> tracks = ref.watch(libraryProvider);
    final Track? current =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar.large(
          title: const Text('MingMusic'),
          actions: <Widget>[
            IconButton(
              tooltip: '添加网络直链',
              onPressed: () => showAddNetworkSheet(context),
              icon: const Icon(Icons.add_link_rounded),
            ),
            const SizedBox(width: 4),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: _NowPlayingCard(track: current),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
            child: Row(
              children: <Widget>[
                Text(
                  '全部音乐',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                Text(
                  '${tracks.length} 首',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: tracks.isEmpty
                      ? null
                      : () => ref
                          .read(playerProvider.notifier)
                          .playQueue(tracks, startIndex: 0),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('播放全部'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyLibrary(),
          )
        else
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (BuildContext context, int i) =>
                TrackTile(track: tracks[i], index: i),
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}

// ---------------------------------------------------------------- 卡片

class _NowPlayingCard extends ConsumerWidget {
  const _NowPlayingCard({required this.track});

  final Track? track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    final Track? current = track;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => openFullPlayer(context),
      child: Container(
        height: 118,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF6D5AE6), Color(0xFF3D2C99)],
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Icon(
                playing ? Icons.graphic_eq_rounded : Icons.headphones_rounded,
                key: ValueKey<bool>(playing),
                size: 40,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    current != null ? '正在播放' : '还没有开始播放',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 2,
                      color: Colors.white.withValues(alpha: 0.66),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    current?.title ?? '从下方挑选一首开始吧',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  if (current != null)
                    Text(
                      '${current.artist} · ${current.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withValues(alpha: 0.66),
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white70, size: 28),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.library_music_outlined,
              size: 52,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.3)),
          const SizedBox(height: 14),
          Text('音乐库空空如也', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('点右上角添加网络直链，或稍后再来看看',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5),
              )),
        ],
      ),
    );
  }
}
