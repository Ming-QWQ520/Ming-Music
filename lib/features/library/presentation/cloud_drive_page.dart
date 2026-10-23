/// 音乐云盘（/user/cloud）：列表 / 播放 / 删除。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/duration_utils.dart';
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart';
import '../../discover/data/netease_providers.dart';
import '../../discover/presentation/widgets/song_actions_sheet.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';

class CloudDrivePage extends ConsumerStatefulWidget {
  const CloudDrivePage({super.key});

  @override
  ConsumerState<CloudDrivePage> createState() => _CloudDrivePageState();
}

class _CloudDrivePageState extends ConsumerState<CloudDrivePage> {
  List<CloudSong>? _songs;
  CloudDriveInfo? _info;
  String? _error;
  int? _deletingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _songs = null;
    });
    try {
      // 需求：云盘显示总歌曲数和总容量（count/size/maxSize 与列表同时拉取）
      final List<dynamic> r = await Future.wait<dynamic>(<Future<dynamic>>[
        ref.read(neteaseRepositoryProvider).cloudList(),
        ref.read(neteaseRepositoryProvider).cloudInfo(),
      ]);
      if (!mounted) return;
      setState(() {
        _songs = r[0] as List<CloudSong>;
        _info = r[1] as CloudDriveInfo;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  List<Track> _asTracks(List<CloudSong> songs) => <Track>[
        for (final CloudSong c in songs) c.song.toTrack(),
      ];

  void _playAt(int index) {
    final List<CloudSong>? songs = _songs;
    if (songs == null || songs.isEmpty) return;
    ref
        .read(playerProvider.notifier)
        .playSongs(_asTracks(songs), startIndex: index, queueTitle: '音乐云盘');
  }

  Future<void> _delete(CloudSong item) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除云盘歌曲'),
        content: Text('确定从云盘删除「${item.song.name}」吗？'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deletingId = item.song.id);
    try {
      await ref.read(neteaseRepositoryProvider).cloudDelete(item.song.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已删除')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingId = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐云盘'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded, size: 22),
            onPressed: _load,
          ),
        ],
      ),
      body: !auth.loggedIn
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.cloud_outlined,
                      size: 48, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text('登录后可查看音乐云盘'),
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
    final List<CloudSong>? songs = _songs;
    if (songs == null) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
      );
    }
    if (songs.isEmpty) {
      return Center(
        child: Text(
          '云盘暂无歌曲\n在网页端或客户端上传后即可在此播放',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13.5,
            height: 1.6,
          ),
        ),
      );
    }
    return Column(
      children: <Widget>[
        // 需求：云盘顶部显示总歌曲数与总容量
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: <Widget>[
              Icon(Icons.cloud_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '共 ${_info?.count ?? songs.length} 首 · 已用 ${_sizeTotal(_info?.size ?? 0)}'
                  '${(_info?.maxSize ?? 0) > 0 ? ' / ${_sizeTotal(_info!.maxSize)}' : ''}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 17,
                backgroundColor: AppConstants.brandColor,
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 10),
              Text('播放全部 (${songs.length})',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppConstants.brandColor,
            onRefresh: _load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: songs.length,
              itemBuilder: (BuildContext context, int index) {
                final CloudSong item = songs[index];
                final Song s = item.song;
                return ListTile(
                  leading: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.cloud_done_outlined, size: 22),
                  ),
                  title: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                  subtitle: Text(
                    '${s.artists} · ${_sizeText(item.fileSize)}'
                    ' · ${Duration(milliseconds: s.durationMs ?? 0).clock}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: _deletingId == s.id
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip: '删除',
                          icon: Icon(Icons.delete_outline_rounded,
                              size: 20,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                          onPressed: () => _delete(item),
                        ),
                  onTap: () => _playAt(index),
                  onLongPress: () => showSongActionsSheet(context, s.toTrack()),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  static String _sizeText(int bytes) {
    if (bytes <= 0) return '未知大小';
    final double mb = bytes / 1024 / 1024;
    if (mb >= 1) return '${mb.toStringAsFixed(1)}MB';
    return '${(bytes / 1024).round()}KB';
  }

  /// 容量展示（GB/MB 自适应；需求：云盘显示总容量）
  static String _sizeTotal(int bytes) {
    if (bytes <= 0) return '0B';
    final double gb = bytes / 1024 / 1024 / 1024;
    if (gb >= 1) return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)}GB';
    final double mb = bytes / 1024 / 1024;
    if (mb >= 1) return '${mb.toStringAsFixed(0)}MB';
    return '${(bytes / 1024).round()}KB';
  }
}
