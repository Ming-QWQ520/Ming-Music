/// 歌曲操作弹窗（⋮）：喜欢 / 添加至歌单 / 下载 / 分享 / 歌手 / MV。
/// 所有入口闭环到真实功能，无占位项。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/platform_actions.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../library/data/download_service.dart';
import '../../../library/domain/track.dart';
import '../../../library/presentation/add_to_playlist_sheet.dart';

/// 弹出歌曲操作菜单
Future<void> showSongActionsSheet(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => _SongActionsSheet(track: track),
  );
}

class _SongActionsSheet extends ConsumerStatefulWidget {
  const _SongActionsSheet({required this.track});

  final Track track;

  @override
  ConsumerState<_SongActionsSheet> createState() => _SongActionsSheetState();
}

class _SongActionsSheetState extends ConsumerState<_SongActionsSheet> {
  bool _downloading = false;

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

  @override
  Widget build(BuildContext context) {
    final bool liked = _isNetease &&
        ref.watch(authProvider.select((AuthState s) => s.likedIds))
            .contains(widget.track.neteaseId);

    return Container(
      decoration: const BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${widget.track.title} - ${widget.track.artist}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            _ActionRow(
              icon: liked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: liked ? AppConstants.brandColor : null,
              label: liked ? '取消喜欢' : '喜欢',
              onTap: _isNetease ? _toggleLike : () => _toast('该歌曲不支持喜欢'),
            ),
            _ActionRow(
              icon: Icons.playlist_add_rounded,
              label: '添加到歌单',
              onTap: _isNetease
                  ? () =>
                      showAddToPlaylistSheet(context, ref, <int>[widget.track.neteaseId!])
                  : () => _toast('该歌曲暂不支持添加到歌单'),
            ),
            _ActionRow(
              icon: Icons.download_rounded,
              label: _downloading ? '下载中…' : '下载',
              onTap: _downloading ? null : () => _download(),
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
            if ((widget.track.mvId ?? 0) > 0)
              _ActionRow(
                icon: Icons.play_circle_outline_rounded,
                label: '观看 MV',
                onTap: () {
                  final GoRouter router = GoRouter.of(context);
                  Navigator.of(context).pop();
                  router.push(
                      '/mv/${widget.track.mvId}?title=${Uri.encodeComponent(widget.track.title)}');
                },
              ),
            const SizedBox(height: 10),
          ],
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
