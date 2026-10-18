/// MingMusic 音频引擎：just_audio 播放内核 + audio_service 前台服务封装。
///
/// ⚠️ 避坑指南 5 —— 音频生命周期：
/// 本类**必须在 App 最顶层初始化**（main.dart 中 `AudioService.init` 完成后
/// 通过 `audioHandlerProvider.overrideWithValue` 注入 ProviderScope），
/// 绝不能在某个页面中创建，否则页面销毁时音频流会随之中断。
///
/// 职责：
///   1. 持有唯一的 [AudioPlayer] 实例，管理播放队列；
///   2. 将 just_audio 的播放事件广播为 MediaSession 状态
///      （通知栏播放/暂停/上一首/下一首、锁屏控制全部由此驱动）；
///   3. 向上层（Riverpod）暴露细粒度流：position/duration/playing/index…
library;

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';

import '../../../core/widgets/cover_image.dart';
import '../../library/domain/track.dart';

class MingAudioHandler extends BaseAudioHandler with SeekHandler {
  MingAudioHandler({ja.AudioPlayer? player})
      : _player = player ?? ja.AudioPlayer() {
    _bindEventStreams();
    // 需求：通知栏始终显示控制栏 —— 服务启动即广播一次完整状态，
    // 避免首次播放事件到达前通知以空 controls 渲染（部分 ROM 会隐藏按钮）。
    _broadcastState(_player.playbackEvent);
  }

  final ja.AudioPlayer _player;

  /// UI 层订阅的平滑进度流（约 200ms 一次）。
  /// audio_service 的 BaseAudioHandler 不内置 positionStream，
  /// 这里基于 just_audio 的 createPositionStream 自建。
  late final Stream<Duration> positionStream = _player.createPositionStream(
    steps: 600,
    minPeriod: const Duration(milliseconds: 16),
    maxPeriod: const Duration(milliseconds: 200),
  );

  /// 通知栏/蓝牙的上一首/下一首由上层（PlayerNotifier）接管，
  /// 以支持随机的洗牌逻辑；未注册时退回内核队列行为。
  Future<void> Function()? _onNextRequest;
  Future<void> Function()? _onPreviousRequest;

  /// 需求：通知栏增加红心 —— 由上层注入 toggleLike 回调；
  /// 喜欢状态变化时经 [setLiked] 同步通知栏图标（空心⇄实心）。
  Future<void> Function()? _onToggleLike;
  bool _liked = false;

  /// 播放内核暴露给 UI 层（进度条等需要 select 精细监听的场景）
  ja.AudioPlayer get player => _player;

  // ---------------------------------------------------------------- init

  void setSkipHandlers({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {
    _onNextRequest = onNext;
    _onPreviousRequest = onPrevious;
  }

  /// 通知栏红心点击 → 上层执行喜欢/取消喜欢（成功后回调 [setLiked]）
  void setLikeHandler(Future<void> Function()? handler) {
    _onToggleLike = handler;
  }

  /// 同步通知栏红心状态（状态变化才重新广播，避免无谓的通知刷新）
  void setLiked(bool liked) {
    if (_liked == liked) return;
    _liked = liked;
    _broadcastState(_player.playbackEvent);
  }

  void _bindEventStreams() {
    _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) =>
          debugPrint('MingAudioHandler playbackEvent error: $e'),
    );
    // 曲目切换时同步 MediaItem（锁屏封面/标题）
    _player.sequenceStateStream
        .map((ja.SequenceState? s) => s?.currentIndex ?? -1)
        .distinct()
        .listen((int i) {
      if (i >= 0) _notifyMediaItem(i);
    });
  }

  // ---------------------------------------------------------------- queue

  /// 装载播放队列并定位到 [initialIndex]
  Future<void> loadQueue(List<Track> tracks, {int initialIndex = 0}) async {
    if (tracks.isEmpty) {
      // 空队列：清空内核与状态，避免 clamp(0, -1) 抛 ArgumentError
      queue.add(<MediaItem>[]);
      await _player.stop();
      return;
    }
    queue.add(tracks.map(_mediaItemOf).toList(growable: false));
    final List<ja.AudioSource> sources = <ja.AudioSource>[
      for (final Track t in tracks) _sourceOf(t),
    ];
    await _player.setAudioSources(
      sources,
      initialIndex: initialIndex.clamp(0, sources.length - 1),
    );
    await _notifyMediaItem(initialIndex);
  }

  ja.AudioSource _sourceOf(Track t) {
    final String src = t.source;
    // 本地文件（本地音乐页）：绝对路径 / file:// URI
    if (src.startsWith('file://')) {
      return ja.AudioSource.uri(Uri.parse(src));
    }
    if (src.startsWith('/')) {
      return ja.AudioSource.uri(Uri.file(src));
    }
    if (t.isNetwork) {
      return ja.AudioSource.uri(Uri.parse(src));
    }
    // AudioSource.asset 需要完整 asset key（含 assets/ 前缀）
    return ja.AudioSource.asset('assets/$src');
  }

  MediaItem _mediaItemOf(Track t) {
    final String? cover = t.cover;
    final bool isUrlCover = cover != null && cover.startsWith('http');
    return MediaItem(
      id: t.id,
      album: t.album,
      title: t.title,
      artist: t.artist,
      duration:
          t.durationMs != null ? Duration(milliseconds: t.durationMs!) : null,
      // 网络封面：异步解析为本地缓存文件（系统通知栏直接读文件，
      // 规避网易 CDN 对部分节点的 403）；asset 封面记录在 extras
      artUri: isUrlCover ? Uri.parse(cover) : null,
      extras: (cover != null && !isUrlCover)
          ? <String, String>{'assetCover': cover}
          : <String, String>{'urlCover': cover ?? ''},
    );
  }

  final Map<String, Uri> _artworkCache = <String, Uri>{};

  Future<Uri?> resolveArtworkUri(String cover) async {
    if (cover.startsWith('http')) {
      // 优先本地缓存文件（修复通知栏封面 403：部分 CDN 节点拒绝
      // 系统通知的直连请求），未缓存时回退网络 URL。
      // 需求「适当放大歌曲封面」：通知栏取原图分辨率（500y500 → 原图），
      // 系统按 largeIcon 缩放后明显更清晰饱满；原图经磁盘缓存仅下载一次。
      final Uri? cached = _artworkCache[cover];
      if (cached != null) return cached;
      try {
        final File? f =
            await CoverImage.cachedFileFor(cover, size: CoverSize.original);
        if (f != null) {
          final Uri uri = Uri.file(f.path);
          _artworkCache[cover] = uri;
          return uri;
        }
      } catch (_) {
        // 原图失败回退 500y500
        try {
          final File? f =
              await CoverImage.cachedFileFor(cover, size: CoverSize.large);
          if (f != null) {
            final Uri uri = Uri.file(f.path);
            _artworkCache[cover] = uri;
            return uri;
          }
        } catch (_) {}
      }
      return Uri.parse(cover);
    }
    final Uri? cached = _artworkCache[cover];
    if (cached != null) return cached;
    try {
      final ByteData data = await rootBundle.load(cover);
      final Directory dir = await getApplicationCacheDirectory();
      final String name = cover.split('/').last;
      final File file = File('${dir.path}/$name');
      if (!file.existsSync()) {
        await file.writeAsBytes(data.buffer.asUint8List());
      }
      final Uri uri = Uri.file(file.path);
      _artworkCache[cover] = uri;
      return uri;
    } catch (e) {
      debugPrint('resolveArtworkUri failed: $e');
      return null;
    }
  }

  Future<void> _notifyMediaItem(int index) async {
    final List<MediaItem> q = queue.value;
    if (index < 0 || index >= q.length) return;
    final MediaItem item = q[index];
    if (item.artUri == null && item.extras?['assetCover'] is String) {
      final Uri? uri =
          await resolveArtworkUri(item.extras!['assetCover'] as String);
      if (uri != null) {
        mediaItem.add(item.copyWith(artUri: uri));
        return;
      }
    }
    if (item.extras?['urlCover'] is String &&
        (item.extras!['urlCover'] as String).startsWith('http')) {
      final Uri? uri =
          await resolveArtworkUri(item.extras!['urlCover'] as String);
      if (uri != null && uri.scheme == 'file') {
        mediaItem.add(item.copyWith(artUri: uri));
        return;
      }
    }
    mediaItem.add(item);
  }

  // ---------------------------------------------------------------- intents

  @override
  Future<void> play() async {
    await _player.play();
    _broadcastState(_player.playbackEvent);
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _broadcastState(_player.playbackEvent);
  }

  @override
  Future<void> skipToNext() async {
    final handler = _onNextRequest;
    if (handler != null) {
      await handler();
    } else {
      await _player.seekToNext();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final handler = _onPreviousRequest;
    if (handler != null) {
      await handler();
    } else {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  /// 自定义通知动作（需求：通知栏红心）。audio_service 把
  /// MediaAction.custom + CustomMediaAction(name) 路由到本回调；
  /// 喜欢操作由上层完成后再回写 [setLiked] 刷新图标。
  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'toggleLike':
        final Future<void> Function()? h = _onToggleLike;
        if (h != null) await h();
        return null;
      default:
        return super.customAction(name, extras);
    }
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  /// 用户从最近任务划掉 App：仅在暂停/空闲时释放前台服务，
  /// 正在播放则继续后台运行（系统会维持 foregroundService）。
  @override
  Future<void> onTaskRemoved() async {
    final PlaybackState s = playbackState.value;
    if (!s.playing) {
      await stop();
    }
  }

  // ---------------------------------------------------------------- broadcast

  /// 将 just_audio 事件映射为 audio_service 的 PlaybackState。
  /// 通知栏按钮组（需求：增加红心、缩小播放控件 —— 4 键排布比 3 键更紧凑）：
  /// 上一首 | 红心 | 播放/暂停 | 下一首（紧凑展示取上一首/播放/下一首）。
  void _broadcastState(ja.PlaybackEvent event) {
    final bool playing = _player.playing;
    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          MediaControl(
            androidIcon: _liked
                ? 'drawable/ic_notif_heart_filled'
                : 'drawable/ic_notif_heart_outline',
            label: _liked ? '取消喜欢' : '喜欢',
            action: MediaAction.custom,
            customAction: const CustomMediaAction(name: 'toggleLike'),
          ),
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: const <ja.ProcessingState, AudioProcessingState>{
          ja.ProcessingState.idle: AudioProcessingState.idle,
          ja.ProcessingState.loading: AudioProcessingState.loading,
          ja.ProcessingState.buffering: AudioProcessingState.buffering,
          ja.ProcessingState.ready: AudioProcessingState.ready,
          ja.ProcessingState.completed: AudioProcessingState.completed,
        }[event.processingState]!,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
        androidCompactActionIndices: const <int>[0, 2, 3],
      ),
    );
  }
}
