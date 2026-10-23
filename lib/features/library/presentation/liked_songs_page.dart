/// 喜欢的歌曲（服务器红心 /likelist → /song/detail 批量补全）。
/// 需求「无网时也可在我的中点击歌单查看」：成功拉取后快照落盘，
/// 请求失败时展示离线快照（歌名按缓存状态着色的逻辑同歌单详情页）。
library;

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../auth/providers/auth_providers.dart';
import '../../auth/presentation/login_sheet.dart';
import '../../discover/data/netease_providers.dart';
import '../../discover/presentation/widgets/song_actions_sheet.dart';
import '../../discover/presentation/widgets/song_tile.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';

class LikedSongsPage extends ConsumerStatefulWidget {
  const LikedSongsPage({super.key});

  @override
  ConsumerState<LikedSongsPage> createState() => _LikedSongsPageState();
}

class _LikedSongsPageState extends ConsumerState<LikedSongsPage> {
  List<Song>? _songs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn || auth.likedIds.isEmpty) {
      if (mounted) setState(() => _songs = const <Song>[]);
      return;
    }
    try {
      final List<int> ids = auth.likedIds.toList(growable: false);
      final List<Song> out = <Song>[];
      // song/detail 一次最多 ~1000 id，按 200 分块稳妥
      for (int i = 0; i < ids.length; i += 200) {
        final List<int> chunk =
            ids.sublist(i, (i + 200).clamp(0, ids.length));
        out.addAll(
            await ref.read(neteaseRepositoryProvider).songDetails(chunk));
      }
      if (!mounted) return;
      setState(() => _songs = out);
      unawaited(_writeDiskCache(out));
    } catch (e) {
      if (!mounted) return;
      // 离线快照兜底（需求：无网也可查看喜欢列表）
      final List<Song>? cached = await _readDiskCache();
      if (!mounted) return;
      if (cached != null && cached.isNotEmpty) {
        setState(() => _songs = cached);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前离线，展示上次缓存的歌曲列表')),
        );
        return;
      }
      setState(() => _songs = const <Song>[]);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('喜欢列表加载失败：$e')),
      );
    }
  }

  Future<Directory> _cacheDir() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory('${support.path}/playlist_cache');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<List<Song>?> _readDiskCache() async {
    try {
      final Directory dir = await _cacheDir();
      final File f = File('${dir.path}/liked.json');
      if (!f.existsSync()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! List<Object?>) return null;
      return <Song>[
        for (final Object? s in decoded)
          if (s is Map<String, Object?>) Song.fromStoredJson(s),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDiskCache(List<Song> songs) async {
    try {
      if (songs.isEmpty) return;
      final Directory dir = await _cacheDir();
      final File f = File('${dir.path}/liked.json');
      await f.writeAsString(
        jsonEncode(<Object?>[for (final Song s in songs) s.toJson()]),
        flush: true,
      );
    } catch (_) {}
  }

  void _playAll(int index) {
    final List<Song>? songs = _songs;
    if (songs == null || songs.isEmpty) return;
    final List<Track> tracks =
        songs.map((Song s) => s.toTrack()).toList(growable: false);
    ref
        .read(playerProvider.notifier)
        .playSongs(tracks, startIndex: index, queueTitle: '我喜欢的音乐');
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('我喜欢的音乐')),
      body: !auth.loggedIn
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.favorite_border_rounded,
                      size: 48, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text('登录后可查看喜欢的音乐'),
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
          : _buildList(auth),
    );
  }

  Widget _buildList(AuthState auth) {
    final List<Song>? songs = _songs;
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
          auth.likedIds.isEmpty
              ? '还没有喜欢的歌曲\n在播放页点击红心即可喜欢'
              : '加载失败，下拉重试',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13.5,
            height: 1.6,
          ),
        ),
      );
    }
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
        ),
        SliverList.builder(
          itemCount: songs.length,
          itemBuilder: (BuildContext context, int index) => SongTile(
            song: songs[index],
            onPlay: () => _playAll(index),
            onMore: () => showSongActionsSheet(context, songs[index].toTrack()),
            onLongPress: () => showSongActionsSheet(context, songs[index].toTrack()),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}
