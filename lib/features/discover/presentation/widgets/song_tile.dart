/// 歌曲条目组件：封面/序号 + 标题 + VIP 徽章 + 副标题。
/// 需求：所有歌曲支持长按弹出统一操作菜单（onLongPress）；
/// 需求修正「无缓存暗淡」：仅无网且未缓存时整行暗淡（歌名/歌手/VIP/封面），
/// 有网一律正常；正在播放行保持红色高亮不受暗淡影响。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/netease_models.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../player/providers/cache_providers.dart'
    show cachedSongIdsProvider, networkAvailableProvider;

/// VIP 徽标（需求：透明背景 + 白色 VIP 字体 + 白色带圆角长方形描边）
class VipBadge extends StatelessWidget {
  const VipBadge({super.key, this.height = 15});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: 1,
        ),
      ),
      child: Text(
        'VIP',
        style: TextStyle(
          color: Colors.white,
          fontSize: height * 0.67,
          height: 1.15,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 歌曲条目
class SongTile extends ConsumerWidget {
  const SongTile({
    super.key,
    required this.song,
    this.trackIndex,
    this.onPlay,
    this.onLongPress,
    this.onMore,
    this.playing = false,
    this.trailing,
  });

  final Song song;

  /// 显示序号（歌单详情场景）；null 显示封面
  final int? trackIndex;

  /// 点击整行 → 播放
  final VoidCallback? onPlay;

  /// 长按整行 → 统一操作菜单（需求：所有歌曲增加长按弹出菜单）
  final VoidCallback? onLongPress;

  /// 右侧三点菜单（详情操作），null 隐藏
  final VoidCallback? onMore;

  /// 正在播放（歌名标红）
  final bool playing;

  /// 行尾自定义组件（替代三点按钮，如播放列表弹窗的删除/拖动）
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // 需求修正：暗淡仅发生在「无网且未缓存」—— 有网时歌曲一律正常
    // 显示（此前按缓存状态着色导致有网也整列发灰）；无网时未缓存歌曲
    // 整行暗淡（歌名/歌手/VIP/封面 同规则 alpha 0.38）
    final Set<int> cachedIds =
        ref.watch(cachedSongIdsProvider).valueOrNull ?? const <int>{};
    final bool online = ref.watch(networkAvailableProvider
        .select((AsyncValue<bool> v) => v.valueOrNull ?? true));
    final int? songId = song.id > 0 ? song.id : null;
    final bool normal =
        playing || songId == null || online || cachedIds.contains(songId);
    final Color titleColor = playing
        ? AppConstants.brandColor
        : normal
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final Color subtitleColor = normal
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38);
    final Color indexColor = normal
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38);
    final Widget cover = CoverImage(src: song.coverUrl, size: 48, radius: 8);
    final Widget? endWidget = trailing ??
        (onMore != null
            ? IconButton(
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                  size: 22,
                ),
                onPressed: onMore,
              )
            : null);

    return InkWell(
      onTap: onPlay,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <Widget>[
            if (trackIndex != null)
              SizedBox(
                width: 32,
                child: Text(
                  '$trackIndex',
                  style: TextStyle(
                    color: indexColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              )
            else
              Opacity(opacity: normal ? 1 : 0.38, child: cover),
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
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (song.isVipOnly) ...<Widget>[
                        const SizedBox(width: 6),
                        Opacity(
                          opacity: normal ? 1 : 0.38,
                          child: const VipBadge(),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.album.isEmpty
                        ? song.artists
                        : '${song.artists} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            if (endWidget != null) endWidget,
          ],
        ),
      ),
    );
  }
}
