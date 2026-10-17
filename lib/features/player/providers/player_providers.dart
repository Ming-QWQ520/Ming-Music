/// 播放器状态管理层。
///
/// ⚠️ 避坑指南 3 —— 重绘与状态管理：
///  - UI 组件必须通过 `select` 只订阅所需字段，例如：
///      `ref.watch(playerProvider.select((s) => s.playing))`
///  - 进度等高频数据走独立的 StreamProvider（positionProvider），
///    且组件外层包裹 RepaintBoundary，把重绘隔离到最小范围。
///  - 严禁监听整个 PlayerState 导致整页 rebuild。
///
/// 网易云集成：playSongs() 在入队前批量调用 /song/url/v1 解析播放直链，
/// 直链约 20 分钟过期（expi:1200），收藏恢复/跨次启动播放时自动重新解析。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart'
    show LoopMode, ProcessingState, SequenceState;

import '../../discover/data/netease_providers.dart';
import '../../discover/data/netease_repository.dart';
import '../../library/domain/track.dart';
import '../../../core/api/netease_models.dart' show SongUrlInfo;
import '../../settings/domain/settings_models.dart' show AudioQualityX;
import '../../settings/providers/settings_providers.dart'
    show audioQualityProvider;
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

  /// 首次 build() 返回前 Riverpod 禁止读写 this.state（抛
  /// "Tried to read the state of an uninitialized provider"）。
  /// 内核流的当前值可能在 build 返回前经微任务送达（BehaviorSubject
  /// 回放），监听回调必须用本标志位挡住这些早期事件。
  bool _ready = false;

  /// 最近一次已生效的状态：依赖变化导致重建时恢复现场，避免 UI 跳变
  PlayerState? _lastState;

  /// 播放直链内存缓存（neteaseId → url），队列重播免二次请求
  final Map<int, SongUrlInfo> _urlCache = <int, SongUrlInfo>{};

  @override
  set state(PlayerState value) {
    _lastState = value;
    super.state = value;
  }

  @override
  PlayerState build() {
    _handler = ref.watch(audioHandlerProvider);
    _ready = false; // 重建期间静默监听回调，直到新初始值返回

    // 订阅内核细粒度流 → 映射进不可变状态（低频字段，重建代价可控）
    _playingSub = _handler.player.playingStream.listen((bool p) {
      if (!_ready) return;
      state = state.copyWith(playing: p);
    });
    _indexSub = _handler.player.sequenceStateStream
        .map((SequenceState? s) => s?.currentIndex ?? -1)
        .distinct()
        .listen((int i) {
      if (!_ready || i < 0) return;
      state = state.copyWith(index: i);
    });
    _processingSub = _handler.player.processingStateStream
        .map(_mapProcessing)
        .distinct()
        .listen((AppProcessingState ps) {
      if (!_ready) return;
      state = state.copyWith(processing: ps);
    });

    ref.onDispose(() {
      _playingSub?.cancel();
      _indexSub?.cancel();
      _processingSub?.cancel();
    });

    // 通知栏的上一首/下一首交给本 Notifier，保证洗牌/循环逻辑一致
    _handler.setSkipHandlers(onNext: next, onPrevious: previous);

    // ⚠️ 必须返回全新构造的初始值，绝不能 return state ——
    // 首次构建时 state 尚未初始化，读取即抛 StateError（2026-10 启动崩溃根因）。
    // 首次返回默认空状态；重建时恢复最近状态保持连续性。
    final PlayerState initial = _lastState ?? const PlayerState();
    _ready = true;
    return initial;
  }

  static AppProcessingState _mapProcessing(ProcessingState s) => switch (s) {
        ProcessingState.idle => AppProcessingState.idle,
        ProcessingState.loading => AppProcessingState.loading,
        ProcessingState.buffering => AppProcessingState.buffering,
        ProcessingState.ready => AppProcessingState.ready,
        ProcessingState.completed => AppProcessingState.completed,
      };

  // ---------------------------------------------------------------- intents

  /// 播放一批网易云歌曲（发现/搜索/歌单/榜单入口统一走这里）：
  ///  1. 批量解析播放直链（VIP 灰曲自动剔除并提示）；
  ///  2. 装载内核队列并从 [startIndex] 开始播放。
  Future<void> playSongs(
    List<Track> tracks, {
    int startIndex = 0,
    String? queueTitle,
  }) async {
    if (tracks.isEmpty) return;
    final int safeStart = startIndex.clamp(0, tracks.length - 1);
    state = state.copyWith(
      processing: AppProcessingState.loading,
      clearError: true,
      queueTitle: queueTitle,
      clearQueueTitle: queueTitle == null,
    );
    try {
      final List<Track> resolved = await resolveTracks(tracks);
      if (resolved.isEmpty) {
        state = state.copyWith(
          processing: AppProcessingState.idle,
          error: '暂时没有可播放的歌曲（VIP 或版权受限）',
        );
        return;
      }
      // 起点 id 对齐：解析过程可能剔除灰曲，按下标近似定位
      final Track wanted = tracks[safeStart];
      int startIdx = resolved.indexWhere((Track t) => t.id == wanted.id);
      if (startIdx < 0) {
        startIdx = safeStart.clamp(0, resolved.length - 1);
      }
      state = state.copyWith(
        queue: resolved,
        index: startIdx,
        loaded: true,
        processing: AppProcessingState.buffering,
      );
      await _handler.loadQueue(resolved, initialIndex: startIdx);
      await _handler.play();
    } catch (e) {
      state = state.copyWith(
        processing: AppProcessingState.idle,
        error: '加载播放列表失败：$e',
      );
    }
  }

  /// 批量解析网易云直链：命中内存缓存直接复用，未命中的批量请求。
  /// 不可播（VIP 拿不到链接）的曲目剔除，试听片段保留（freeTrial）。
  Future<List<Track>> resolveTracks(List<Track> tracks) async {
    final List<Track> out = <Track>[];
    final Map<int, Track> pending = <int, Track>{};

    for (final Track t in tracks) {
      if (t.neteaseId == null) {
        out.add(t); // 非网易云（自定义直链）：直接可用
        continue;
      }
      final SongUrlInfo? cached = _urlCache[t.neteaseId!];
      if (cached != null) {
        if (cached.playable) out.add(t.copyWith(source: cached.url));
        continue; // 缓存命中但不可播：剔除（VIP 灰曲）
      }
      pending[t.neteaseId!] = t;
    }

    if (pending.isNotEmpty) {
      final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
      final String level = ref.read(audioQualityProvider).apiValue;
      final List<SongUrlInfo> urls =
          await repo.songUrls(pending.keys.toList(), level: level);
      for (final SongUrlInfo u in urls) {
        final Track? t = pending[u.id];
        if (t == null) continue;
        _urlCache[u.id] = u;
        if (u.playable) {
          out.add(t.copyWith(source: u.url));
        }
      }
    }
    return out;
  }

  /// 收藏列表/恢复场景：队列里存在未解析直链的曲目时，整体重新解析。
  Future<void> requeueIfNeeded() async {
    final bool needsResolve = state.queue.any((Track t) => t.needsUrlResolve);
    if (!needsResolve) return;
    final List<Track> resolved = await resolveTracks(state.queue);
    if (resolved.isEmpty) {
      state = state.copyWith(error: '播放链接已失效，且重新获取失败');
      return;
    }
    int startIdx = state.index.clamp(0, resolved.length - 1);
    if (startIdx >= resolved.length) startIdx = resolved.length - 1;
    state = state.copyWith(queue: resolved, index: startIdx);
    await _handler.loadQueue(resolved, initialIndex: startIdx);
  }

  /// 队列内定位播放（播放列表弹窗点击）
  Future<void> playAt(int index) async {
    if (!state.hasQueue) return;
    final int safe = index.clamp(0, state.queue.length - 1);
    final Track target = state.queue[safe];
    if (target.needsUrlResolve) {
      await requeueIfNeeded();
      final int idx2 = state.queue.indexWhere((Track t) => t.id == target.id);
      await _jumpTo(idx2 < 0 ? safe : idx2);
      return;
    }
    await _jumpTo(safe);
  }

  /// 移除队列指定曲目（播放列表弹窗）
  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    final bool wasCurrent = index == state.index;
    final List<Track> next = List<Track>.of(state.queue)..removeAt(index);
    if (next.isEmpty) {
      await _handler.loadQueue(const <Track>[]);
      state = state.copyWith(
        queue: next,
        index: 0,
        loaded: false,
        playing: false,
        clearQueueTitle: true,
        processing: AppProcessingState.idle,
      );
      return;
    }
    int nextIndex = state.index;
    if (wasCurrent) {
      nextIndex = index.clamp(0, next.length - 1);
    } else if (index < state.index) {
      nextIndex = state.index - 1;
    }
    state = state.copyWith(queue: next, index: nextIndex);
    if (wasCurrent) {
      await _handler.loadQueue(next, initialIndex: nextIndex);
      await _handler.play();
    }
  }

  /// 清空队列（播放列表弹窗垃圾桶）
  Future<void> clearQueue() async {
    await _handler.loadQueue(const <Track>[]);
    state = state.copyWith(
      queue: const <Track>[],
      index: 0,
      loaded: false,
      playing: false,
      clearQueueTitle: true,
      processing: AppProcessingState.idle,
    );
  }

  Future<void> playPause() async {
    final PlayerState s = state;
    if (!s.hasQueue) return;
    if (s.playing) {
      await _handler.pause();
    } else {
      // 队列直链可能已过期（跨次启动/长时间挂起）：先尝试恢复
      if (s.processing == AppProcessingState.idle) {
        await requeueIfNeeded();
      }
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
