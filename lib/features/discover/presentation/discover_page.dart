/// 发现页（App 首页）：排行榜入口 / 推荐歌单 / 热搜词，参考图 1/2/4。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../data/netease_providers.dart';
import '../data/netease_repository.dart' show kToplists;
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
          // 需求：发现顶部增加 Zephyr-Music 推荐页顶部的歌单（样式一致）
          const SliverToBoxAdapter(child: _PersonalizedSection()),
          const SliverToBoxAdapter(child: _ToplistsSection()),
          const SliverToBoxAdapter(child: _HotWordsSection()),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 排行榜

class _ToplistsSection extends StatelessWidget {
  const _ToplistsSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionHeader(title: '排行榜'),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: kToplists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (BuildContext context, int index) {
                final (int id, String name, int color) = (
                  kToplists[index].id,
                  kToplists[index].name,
                  kToplists[index].color,
                );
                return _ToplistCard(id: id, name: name, color: Color(color));
              },
            ),
          ),
        ],
      ),
    );
  }
}

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

/// 推荐歌单（需求：对齐 Zephyr-Music 推荐页顶部样式 —— 方形圆角封面、
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
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _SectionHeader(title: '推荐歌单'),
              SizedBox(
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
            ],
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
        return Padding(
          padding: const EdgeInsets.only(top: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _SectionHeader(title: '热搜榜'),
              Padding(
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
                            fontWeight:
                                i < 3 ? FontWeight.w600 : FontWeight.w400,
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
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 通用

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
