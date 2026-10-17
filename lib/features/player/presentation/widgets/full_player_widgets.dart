/// 播放页公共部件：顶部栏（收起 / 标题 / 详情）与平板双列布局。
///
/// 平板双列规范（需求 2）：
///  - 左列：大尺寸封面 + 进度条 + 控制器；
///  - 右列：滚动歌词 + 详情面板。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/duration_utils.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../library/domain/track.dart';
import '../../../library/providers/library_providers.dart';
import '../../providers/player_providers.dart';
import 'control_bar.dart';
import 'lyrics_view.dart';
import 'progress_bar.dart';
import 'rotating_cover.dart';

// ---------------------------------------------------------------- 顶部栏

class PlayerTopBar extends ConsumerWidget {
  const PlayerTopBar({super.key, required this.onDetail});

  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                size: 30, color: Colors.white),
            tooltip: '收起',
          ),
          const Spacer(),
          Text(
            '正在播放',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 3,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onDetail,
            icon: const Icon(Icons.more_horiz_rounded,
                size: 24, color: Colors.white),
            tooltip: '详情',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 平板布局

class TabletPlayerBody extends ConsumerWidget {
  const TabletPlayerBody({super.key, required this.onDetail});

  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // 左列：封面 + 进度 + 控制
          Expanded(
            flex: 11,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Expanded(child: RotatingCover()),
                const SizedBox(height: 12),
                // ConstrainedBox(maxWidth) 而非固定 width：
                // 600~900dp 窗口下自动收缩，遵守响应式布局规范
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: const PlayerProgressBar(),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: const PlayerControlBar(iconScale: 1.12),
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
          const SizedBox(width: 28),
          // 右列：歌词 + 详情面板
          Expanded(
            flex: 9,
            child: Column(
              children: <Widget>[
                Expanded(child: LyricsView(dense: true)),
                const SizedBox(height: 14),
                TrackDetailPanel(onDetail: onDetail),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 详情面板

/// 平板右栏底部的曲目详情面板（非玻璃材质，仅表面高光）
class TrackDetailPanel extends ConsumerWidget {
  const TrackDetailPanel({super.key, required this.onDetail});

  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String id = track?.id ?? '';
    final bool fav = ref
        .watch(favoriteIdsProvider.select((Set<String> s) => s.contains(id)));

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.white.withValues(alpha: 0.07),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: <Widget>[
          CoverImage(src: track?.cover, size: 56, radius: 14),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  track?.album ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _metaLine(track),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => ref.read(favoriteIdsProvider.notifier).toggle(id),
            icon: Icon(
              fav ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
              color: fav ? const Color(0xFFFF7BA0) : Colors.white70,
            ),
            tooltip: fav ? '取消收藏' : '收藏',
          ),
          IconButton(
            onPressed: onDetail,
            icon: const Icon(Icons.info_outline_rounded, color: Colors.white70),
            tooltip: '详情面板',
          ),
        ],
      ),
    );
  }

  String _metaLine(Track? track) {
    if (track == null) return '未在播放';
    final String duration = track.durationMs != null
        ? Duration(milliseconds: track.durationMs!).clock
        : '--:--';
    return '${track.artist} · $duration · ${track.isNetwork ? '在线' : '本地'}';
  }
}
