/// 播放器状态管理层。
///
/// ⚠️ 避坑指南 3 —— 重绘与状态管理：
///  - UI 组件必须通过 `select` 只订阅所需字段，例如：
///      `ref.watch(playerProvider.select((s) => s.playing))`
///  - 进度等高频数据走独立的 StreamProvider（positionProvider），
///    且组件外层包裹 RepaintBoundary，把重绘隔离到最小范围。
///  - 严禁监听整个 PlayerState 导致整页 rebuild。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart'
    show LoopMode, ProcessingState, SequenceState;

import '../../library/domain/track.dart';
import '../domain/player_state.dart';
import '../services/ming_audio_handler.dart';

/// 导出状态模型：UI 层只需 import player_providers 即可获得
/// PlayerState / AppProcessingState / RepeatMode 类型。
export '../domain/player_state.dart';

/// 由 main.dart 注入的全局唯一 AudioHandler（音频生命周期锚点，避坑指南 5）
final Provider<MingAudioHandler> audioHandlerProvider =
    Provider<MingAudioHandler>(
  (Ref ref) => throw UnimplementedError('必须在 main.dart 中 override 注入'),
);

/// 播放进度流（约 200ms 一次）—— 仅进度条/歌词等局部组件订阅
final StreamProvider<Duration> positionProvider = StreamProvider<Duration>(
  (Ref ref) => ref.watch(audioHandlerProvider).positionStream,
);

/// 缓冲进度流
final StreamProvider<Duration> bufferedPositionProvider =
    StreamProvider<Duration>(
  (Ref ref) => ref.watch(audioHandlerProvider).player.bufferedPositionStream,
);

/// 当前曲目时长流
final StreamProvider<Duration> durationProvider = StreamProvider<Duration>(
  (Ref ref) => ref
      .watch(audioHandlerProvider)
      .player
      .durationStream
      .map((Duration? d) => d ?? Duration.zero),
);

/// 播放器主状态
final NotifierProvider<PlayerNotifier, PlayerState> playerProvider =
    NotifierProvider<PlayerNotifier, PlayerState>(PlayerNotifier.new);

/// 细粒度选择器（常用字段快捷方式，组件内建议配合 select 使用）
final Provider<bool> isPlayingProvider = Provider<bool>(
  (Ref ref) => ref.watch(playerProvider.select((PlayerState s) => s.playing)),
);

final Provider<bool> hasQueueProvider = Provider<bool>(
  (Ref ref) => ref.watch(playerProvider.select((PlayerState s) => s.hasQueue)),
);

class PlayerNotifier extends Notifier<PlayerState> {
  late MingAudioHandler _handler;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int>? _indexSub;
  StreamSubscription<AppProcessingState>? _processingSub;
  final Random _random = Random();

  @override
  PlayerState build() {
    _handler = ref.watch(audioHandlerProvider);

    // 订阅内核细粒度流 → 映射进不可变状态（低频字段，重建代价可控）
    _playingSub = _handler.player.playingStream.listen((bool p) {
      state = state.copyWith(playing: p);
    });
    _indexSub = _handler.player.sequenceStateStream
        .map((SequenceState? s) => s?.currentIndex ?? -1)
        .distinct()
        .listen((int i) {
      if (i >= 0) state = state.copyWith(index: i);
    });
    _processingSub = _handler.player.processingStateStream
        .map(_mapProcessing)
        .distinct()
        .listen((AppProcessingState ps) {
      state = state.copyWith(processing: ps);
    });

    ref.onDispose(() {
      _playingSub?.cancel();
      _indexSub?.cancel();
      _processingSub?.cancel();
    });

    // 通知栏的上一首/下一首交给本 Notifier，保证洗牌/循环逻辑一致
    _handler.setSkipHandlers(onNext: next, onPrevious: previous);

    return state;
  }

  static AppProcessingState _mapProcessing(ProcessingState s) => switch (s) {
        ProcessingState.idle => AppProcessingState.idle,
        ProcessingState.loading => AppProcessingState.loading,
        ProcessingState.buffering => AppProcessingState.buffering,
        ProcessingState.ready => AppProcessingState.ready,
        ProcessingState.completed => AppProcessingState.completed,
      };

  // ---------------------------------------------------------------- intents

  /// 播放一个队列（点击列表 / 收藏页 / 全部播放）
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    final int safe = startIndex.clamp(0, tracks.length - 1);
    state = state.copyWith(
      queue: tracks,
      index: safe,
      loaded: true,
      clearError: true,
    );
    try {
      await _handler.loadQueue(tracks, initialIndex: safe);
      await _handler.play();
    } catch (e) {
      state = state.copyWith(error: '播放失败：$e');
    }
  }

  Future<void> playPause() async {
    final PlayerState s = state;
    if (!s.hasQueue) return;
    if (s.playing) {
      await _handler.pause();
    } else {
      // 播完自然停止后再次点击 → 从头播放
      if (s.processing == AppProcessingState.completed) {
        await _handler.seek(Duration.zero);
      }
      await _handler.play();
    }
  }

  Future<void> next() => _jumpTo(_targetIndex(forward: true));

  Future<void> previous() async {
    // 业界惯例：进度超过 3 秒优先回到本曲开头
    final Duration pos = _handler.player.position;
    if (pos > const Duration(seconds: 3)) {
      await _handler.seek(Duration.zero);
      return;
    }
    await _jumpTo(_targetIndex(forward: false));
  }

  int _targetIndex({required bool forward}) {
    final int len = state.queue.length;
    if (len <= 1) return 0;
    if (state.shuffle) {
      int candidate = state.index;
      while (candidate == state.index) {
        candidate = _random.nextInt(len);
      }
      return candidate;
    }
    if (forward) {
      return (state.index + 1) % len;
    }
    return (state.index - 1 + len) % len;
  }

  Future<void> _jumpTo(int index) async {
    if (!state.hasQueue) return;
    final int safe = index.clamp(0, state.queue.length - 1);
    state = state.copyWith(index: safe);
    await _handler.player.seek(Duration.zero, index: safe);
    if (!state.playing) {
      await _handler.play();
    }
  }

  Future<void> seek(Duration position) => _handler.seek(position);

  Future<void> toggleShuffle() async {
    state = state.copyWith(shuffle: !state.shuffle);
  }

  /// off → all → one → off（Dart 3 switch 表达式）
  Future<void> cycleRepeat() async {
    final RepeatMode nextMode = switch (state.repeat) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    state = state.copyWith(repeat: nextMode);
    // single-loop 交给内核循环；其余由上层逻辑负责
    await _handler.player
        .setLoopMode(nextMode == RepeatMode.one ? LoopMode.one : LoopMode.off);
  }

  Future<void> setSpeed(double speed) async {
    state = state.copyWith(speed: speed);
    await _handler.setSpeed(speed);
  }

  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }
}
