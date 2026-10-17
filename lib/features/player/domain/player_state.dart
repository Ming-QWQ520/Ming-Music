/// 播放器状态模型（Riverpod 不可变状态）。
///
/// 设计要点（避坑指南 3）：
///  - 高频数据（position/buffered）**不进入**本模型，而是通过独立的
///    StreamProvider 暴露，UI 使用 `select` 只订阅自己关心的字段，
///    避免整页频繁 rebuild。
library;

import '../../library/domain/track.dart';

/// 循环模式
enum RepeatMode { off, all, one }

/// 归一化的处理状态（映射 just_audio 的 ProcessingState）
enum AppProcessingState { idle, loading, buffering, ready, completed }

/// 播放器全局状态
class PlayerState {
  const PlayerState({
    this.queue = const <Track>[],
    this.index = 0,
    this.playing = false,
    this.shuffle = false,
    this.repeat = RepeatMode.off,
    this.speed = 1.0,
    this.loaded = false,
    this.processing = AppProcessingState.idle,
    this.error,
  });

  final List<Track> queue;
  final int index;
  final bool playing;
  final bool shuffle;
  final RepeatMode repeat;
  final double speed;
  final bool loaded;
  final AppProcessingState processing;

  /// 最近一次播放错误（null 表示正常），UI 监听后以 SnackBar 提示
  final String? error;

  bool get hasQueue => queue.isNotEmpty;

  Track? get currentTrack {
    if (!hasQueue || index < 0 || index >= queue.length) return null;
    return queue[index];
  }

  PlayerState copyWith({
    List<Track>? queue,
    int? index,
    bool? playing,
    bool? shuffle,
    RepeatMode? repeat,
    double? speed,
    bool? loaded,
    AppProcessingState? processing,
    String? error,
    bool clearError = false,
  }) {
    return PlayerState(
      queue: queue ?? this.queue,
      index: index ?? this.index,
      playing: playing ?? this.playing,
      shuffle: shuffle ?? this.shuffle,
      repeat: repeat ?? this.repeat,
      speed: speed ?? this.speed,
      loaded: loaded ?? this.loaded,
      processing: processing ?? this.processing,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
