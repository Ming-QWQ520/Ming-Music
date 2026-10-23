/// 歌曲长按菜单（需求：全部歌曲统一长按弹出，从上到下）：
///  - 横铺头部：歌曲封面 + 歌曲名称（下方歌手名称）；
///  - 下一首播放 / 喜欢·取消喜欢 / 下载 / 评论(评论数) / 分享 /
///    歌手 / 创作者 / 专辑 / 更多乐谱 / 删除（移除歌单，歌单场景显示）。
/// 所有入口闭环到真实功能，无占位项。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/platform_actions.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../comments/providers/comments_providers.dart'
    show songCommentCountProvider;
import '../../../library/data/download_service.dart';
import '../../../library/domain/track.dart';
import '../../../player/providers/player_providers.dart';
import '../../data/netease_providers.dart';

/// 弹出歌曲操作菜单
///
/// [playlistId] 传入时显示「删除（移除歌单）」；[onRemoved] 在移除成功后
/// 回调（供歌单页刷新列表）。
Future<void> showSongActionsSheet(
  BuildContext context,
  Track track, {
  int? playlistId,
  VoidCallback? onRemoved,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (BuildContext ctx) => _SongActionsSheet(
      track: track,
      playlistId: playlistId,
      onRemoved: onRemoved,
    ),
  );
}

class _SongActionsSheet extends ConsumerStatefulWidget {
  const _SongActionsSheet({
    required this.track,
    this.playlistId,
    this.onRemoved,
  });

  final Track track;
  final int? playlistId;
  final VoidCallback? onRemoved;

  @override
  ConsumerState<_SongActionsSheet> createState() => _SongActionsSheetState();
}

class _SongActionsSheetState extends ConsumerState<_SongActionsSheet> {
  bool _downloading = false;
  bool _removing = false;

  /// 底部弹窗 pop 后自身 context 失效：提前持有 messenger
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _messenger = ScaffoldMessenger.of(context);
    });
  }

  bool get _isNetease => (widget.track.neteaseId ?? 0) > 0;

  void _toast(String msg) {
    _messenger?.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggleLike() async {
    final String? error = await ref
        .read(authProvider.notifier)
        .toggleLikeSong(widget.track.neteaseId ?? 0);
    if (!mounted) return;
    if (error == null) {
      final bool liked =
          ref.read(authProvider).likedIds.contains(widget.track.neteaseId);
      _toast(liked ? '已加入「我喜欢的音乐」' : '已取消喜欢');
    } else {
      _toast(error);
    }
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final DownloadResult r = await downloadTrack(ref, widget.track);
    if (!mounted) return;
    setState(() => _downloading = false);
    _toast(r.message);
  }

  /// 需求「下一首播放」：插入当前曲目之后，不打断正在播放的歌曲
  Future<void> _playNext() async {
    Navigator.of(context).pop();
    final String? error =
        await ref.read(playerProvider.notifier).insertNext(widget.track);
    _toast(error ?? '已添加到下一首播放');
  }

  /// 需求「删除（移除歌单）」：歌单场景把歌曲从当前歌单移除
  Future<void> _removeFromPlaylist() async {
    if (_removing || widget.playlistId == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('移出歌单'),
        content:
            Text('确定将「${widget.track.title}」从当前歌单中移除吗？'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _removing = true);
    try {
      await ref.read(neteaseRepositoryProvider).playlistTracks(
            playlistId: widget.playlistId!,
            trackIds: <int>[widget.track.neteaseId!],
            add: false,
          );
      widget.onRemoved?.call();
      if (!mounted) return;
      setState(() => _removing = false);
      _toast('已从歌单移除');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _removing = false);
      _toast('移除失败：$e');
    }
  }

  void _push(String route, {Object? extra}) {
    Navigator.of(context).pop();
    GoRouter.of(context).push(route, extra: extra);
  }

  @override
  Widget build(BuildContext context) {
    final bool liked = _isNetease &&
        ref.watch(authProvider.select((AuthState s) => s.likedIds))
            .contains(widget.track.neteaseId);

    // 评论数（需求：评论(评论数)）—— 异步加载，未就绪时仅显示「评论」
    final int? songId = widget.track.neteaseId;
    final int commentCount = songId == null || songId <= 0
        ? 0
        : ref.watch(songCommentCountProvider(songId)).value ?? 0;

    return Container(
      constraints: const BoxConstraints(maxHeight: 560),
      decoration: const BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // ---- 横铺头部：封面 + 歌名（下方歌手名）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Row(
                  children: <Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CoverImage(
                        src: widget.track.cover,
                        size: 52,
                        radius: 8,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15.5, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white10),
              _ActionRow(
                icon: Icons.queue_music_rounded,
                label: '下一首播放',
                onTap: () => _playNext(),
              ),
              _ActionRow(
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: liked ? AppConstants.brandColor : null,
                label: liked ? '取消喜欢' : '喜欢',
                onTap: _isNetease ? _toggleLike : () => _toast('该歌曲不支持喜欢'),
              ),
              _ActionRow(
                icon: Icons.download_rounded,
                label: _downloading ? '下载中…' : '下载',
                onTap: _downloading ? null : () => _download(),
              ),
              _ActionRow(
                icon: Icons.mode_comment_outlined,
                label: commentCount > 0 ? '评论 ($commentCount)' : '评论',
                onTap: () => _push('/comments', extra: widget.track),
              ),
              _ActionRow(
                icon: Icons.share_rounded,
                label: '分享',
                onTap: () async {
                  final int? id = widget.track.neteaseId;
                  final String text = id != null && id > 0
                      ? '${widget.track.title} - ${widget.track.artist} '
                          'https://music.163.com/#/song?id=$id'
                      : '${widget.track.title} - ${widget.track.artist}';
                  final bool ok = await PlatformActions.shareText(text);
                  if (!ok && mounted) _toast('分享不可用');
                },
              ),
              _ActionRow(
                icon: Icons.person_outline_rounded,
                label: '歌手',
                onTap: widget.track.artistId != null && widget.track.artistId! > 0
                    ? () => _push(
                        '/artist/${widget.track.artistId}?name=${Uri.encodeComponent(widget.track.artist)}')
                    : () => _toast('暂无歌手信息'),
              ),
              _ActionRow(
                icon: Icons.edit_note_rounded,
                label: '创作者',
                onTap: _isNetease
                    ? () => _push('/wiki/${widget.track.neteaseId}')
                    : () => _toast('该歌曲暂无创作者信息'),
              ),
              _ActionRow(
                icon: Icons.album_outlined,
                label: '专辑',
                onTap: widget.track.albumId != null && widget.track.albumId! > 0
                    ? () => _push(
                        '/album/${widget.track.albumId}?name=${Uri.encodeComponent(widget.track.album)}')
                    : () => _toast('暂无专辑信息'),
              ),
              _ActionRow(
                icon: Icons.library_music_outlined,
                label: '更多乐谱',
                onTap: _isNetease
                    ? () => _push('/wiki/${widget.track.neteaseId}')
                    : () => _toast('该歌曲暂无乐谱'),
              ),
              if (widget.playlistId != null && _isNetease)
                _ActionRow(
                  icon: Icons.playlist_remove_rounded,
                  label: _removing ? '移除中…' : '删除（移除歌单）',
                  color: _removing ? null : const Color(0xFFFF6B6B),
                  onTap: _removing ? null : () => _removeFromPlaylist(),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bool disabled = onTap == null;
    return ListTile(
      visualDensity: VisualDensity.compact,
      leading: Icon(icon,
          size: 22,
          color: disabled
              ? (color ?? Colors.white70).withValues(alpha: 0.35)
              : color ?? Colors.white70),
      title: Text(label,
          style: TextStyle(
              fontSize: 15,
              color: disabled ? Colors.white38 : null)),
      onTap: onTap,
    );
  }
}
