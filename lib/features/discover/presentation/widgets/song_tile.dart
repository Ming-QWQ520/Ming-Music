/// 歌曲条目组件：参考图6 歌单列表行 —— 封面/序号 + 标题 + VIP 徽章 + 副标题。
library;

import 'package:flutter/material.dart';

import '../../../../core/api/netease_models.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/widgets/cover_image.dart';

/// VIP 徽章（红底白字小圆角，参考图1/3/6 样式）
class VipBadge extends StatelessWidget {
  const VipBadge({super.key, this.height = 15});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: AppConstants.brandColor.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'VIP',
        style: TextStyle(
          color: Colors.white,
          fontSize: height * 0.73,
          height: 1.1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 歌曲条目
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    this.trackIndex,
    this.onPlay,
    this.onMore,
    this.playing = false,
    this.trailing,
  });

  final Song song;

  /// 显示序号（歌单详情场景）；null 显示封面
  final int? trackIndex;

  /// 点击整行 → 播放
  final VoidCallback? onPlay;

  /// 右侧三点菜单（详情操作），null 隐藏
  final VoidCallback? onMore;

  /// 正在播放（歌名标红）
  final bool playing;

  /// 行尾自定义组件（替代三点按钮，如播放列表弹窗的删除/拖动）
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color titleColor =
        playing ? AppConstants.brandColor : theme.colorScheme.onSurface;
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
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              )
            else
              CoverImage(
                src: song.coverUrl,
                size: 48,
                radius: 8,
              ),
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
                        const VipBadge(),
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
                      color: theme.colorScheme.onSurfaceVariant,
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
