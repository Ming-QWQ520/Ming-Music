/// 收藏页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/track.dart';
import '../providers/library_providers.dart';
import 'track_tile.dart';

class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> tracks = ref.watch(libraryProvider);
    final Set<String> favIds = ref.watch(favoriteIdsProvider);
    final List<Track> favorites = tracks
        .where((Track t) => favIds.contains(t.id))
        .toList(growable: false);

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar.large(
          title: const Text('收藏'),
          actions: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Center(
                child: Text(
                  '${favorites.length} 首',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.55),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (favorites.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyFavorites(),
          )
        else
          SliverList.builder(
            itemCount: favorites.length,
            itemBuilder: (BuildContext context, int i) => TrackTile(
              track: favorites[i],
              index: i,
              // 关键：播放队列 = 收藏子集本身，
              // 否则会用收藏下标去索引全库队列导致播错歌
              queue: favorites,
            ),
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.favorite_outline_rounded,
              size: 52,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.3)),
          const SizedBox(height: 14),
          Text('还没有收藏的曲目', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('在列表或播放页点击爱心即可收藏',
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
