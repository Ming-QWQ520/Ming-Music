/// 本地音乐（MediaStore 音频库扫描 + 本地播放）。
///
/// 第十五批需求：授权同意并扫描成功后，将歌曲总数持久化
///（localMusicCountProvider），我的页「本地音乐」tile 副标题同步显示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/duration_utils.dart' show DurationX;
import '../../../core/utils/platform_actions.dart';
import '../data/local_music_count.dart' show localMusicCountProvider;
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';

class LocalMusicPage extends ConsumerStatefulWidget {
  const LocalMusicPage({super.key});

  @override
  ConsumerState<LocalMusicPage> createState() => _LocalMusicPageState();
}

class _LocalMusicPageState extends ConsumerState<LocalMusicPage> {
  List<Map<String, Object?>>? _files;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Android 13+ 读音频 = READ_MEDIA_AUDIO；12- = READ_EXTERNAL_STORAGE
    bool granted = false;
    try {
      final PermissionStatus s = await Permission.audio.request();
      granted = s.isGranted;
      if (!granted) {
        final PermissionStatus s2 = await Permission.storage.request();
        granted = s2.isGranted;
      }
    } catch (_) {
      granted = false;
    }
    if (!granted) {
      if (mounted) setState(() => _denied = true);
      return;
    }
    final List<Map<String, Object?>> files =
        await PlatformActions.localAudioFiles();
    if (!mounted) return;
    setState(() {
      _files = files;
      _denied = false;
    });
    // 第十五批需求：授权同意 + 扫描成功 → 持久化总数供我的页显示
    ref.read(localMusicCountProvider.notifier).set(files.length);
  }

  List<Track> _asTracks(List<Map<String, Object?>> files) => <Track>[
        for (final Map<String, Object?> f in files)
          Track(
            id: 'local_${f['id']}',
            title: '${f['title'] ?? '未知曲目'}',
            artist: '${f['artist'] ?? '未知歌手'}',
            album: '${f['album'] ?? '本地音乐'}',
            source: '${f['path'] ?? ''}',
            durationMs: (f['duration'] as num?)?.toInt(),
            isNetwork: false,
            isCustom: false,
          ),
      ];

  void _playAt(int index) {
    final List<Map<String, Object?>>? files = _files;
    if (files == null || files.isEmpty) return;
    ref
        .read(playerProvider.notifier)
        .playSongs(_asTracks(files), startIndex: index, queueTitle: '本地音乐');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool loaded = _files != null && !_denied;
    return Scaffold(
      appBar: AppBar(title: const Text('本地音乐')),
      floatingActionButton: (loaded && _files!.isNotEmpty)
          ? FloatingActionButton.extended(
              backgroundColor: AppConstants.brandColor,
              foregroundColor: Colors.white,
              heroTag: 'rescan',
              onPressed: () {
                setState(() => _files = null);
                _load();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新扫描'),
            )
          : null,
      body: _denied
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.folder_off_rounded,
                      size: 46, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text('需要「音频」权限以扫描本地音乐'),
                  const SizedBox(height: 14),
                  OutlinedButton(onPressed: _load, child: const Text('重试授权')),
                  TextButton(
                    onPressed: openAppSettings,
                    child: const Text('前往系统设置'),
                  ),
                ],
              ),
            )
          : _buildList(theme),
    );
  }

  Widget _buildList(ThemeData theme) {
    final List<Map<String, Object?>>? files = _files;
    if (files == null) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
      );
    }
    if (files.isEmpty) {
      return Center(
        child: Text(
          '未在媒体库中找到音频文件\n将音乐复制到设备后点击右上角刷新',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 13.5,
            height: 1.6,
          ),
        ),
      );
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 17,
                backgroundColor: AppConstants.brandColor,
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 10),
              Text('播放全部 (${files.length})',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            // 第十六批：底部留白防 Mini 条遮挡末尾行
            padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + 96),
            itemCount: files.length,
            itemBuilder: (BuildContext context, int index) {
              final Map<String, Object?> f = files[index];
              return ListTile(
                leading: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.music_note_rounded, size: 22),
                ),
                title: Text(
                  '${f['title'] ?? '未知曲目'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
                subtitle: Text(
                  '${f['artist'] ?? '未知歌手'} · ${f['album'] ?? '本地音乐'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: Text(
                  Duration(milliseconds: (f['duration'] as num?)?.toInt() ?? 0)
                      .clock,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                onTap: () => _playAt(index),
              );
            },
          ),
        ),
      ],
    );
  }
}
