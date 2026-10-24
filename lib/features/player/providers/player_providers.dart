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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart'
    show LoopMode, ProcessingState, SequenceState;

import '../../auth/providers/auth_providers.dart' show authProvider, AuthState;
import '../../../core/utils/platform_actions.dart';
import '../../discover/data/netease_providers.dart';
import '../../discover/data/netease_repository.dart';
import '../../library/domain/track.dart';
import '../../../core/api/netease_models.dart' show Song, SongUrlInfo;
import '../../settings/domain/settings_models.dart'
    show AudioQuality, AudioQualityX;
import '../../settings/providers/settings_providers.dart'
    show
        audioQualityProvider,
        cacheLimitProvider,
        listenCacheProvider,
        preloadNextProvider,
        sharedPreferencesProvider;
import '../domain/player_state.dart';
import '../services/ming_audio_handler.dart';
import 'cache_providers.dart' show refreshCacheProviders;
import '../services/queue_persistence.dart';
import '../services/song_cache.dart';

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

/// 队列持久化 + 历史快照 + 播放统计服务
final Provider<QueuePersistence> queuePersistenceProvider =
    Provider<QueuePersistence>(
  (Ref ref) => QueuePersistence(ref.watch(sharedPreferencesProvider)),
);

/// 边听边缓存 / 预加载服务（应用级单例，应用生命周期内常驻）
final Provider<SongCacheService> songCacheProvider =
    Provider<SongCacheService>((Ref ref) => SongCacheService());

/// 缓存配置同步（需求：LRU 默认 3GB 可改 / 可关闭）：
/// listenCache（开关）与 cacheLimitProvider（容量上限）任一变化 →
/// 立即同步到 SongCacheService 单例。挂在应用根（MingMusicApp watch），
/// 不依赖播放状态，冷启动即生效。
final Provider<void> cacheConfigSyncProvider = Provider<void>((Ref ref) {
  final bool enabled = ref.watch(listenCacheProvider);
  final int maxBytes = ref.watch(cacheLimitProvider);
  final SongCacheService svc = ref.watch(songCacheProvider);
  svc.setEnabled(enabled);
  svc.setMaxBytes(maxBytes);
});

/// 队列历史快照（最多 3 个，最新在前；启动时从磁盘恢复）
final NotifierProvider<QueueHistoryNotifier, List<QueueSnapshot>>
    queueHistoryProvider =
    NotifierProvider<QueueHistoryNotifier, List<QueueSnapshot>>(
        QueueHistoryNotifier.new);

class QueueHistoryNotifier extends Notifier<List<QueueSnapshot>> {
  @override
  List<QueueSnapshot> build() {
    final QueuePersistence persistence = ref.watch(queuePersistenceProvider);
    return persistence.loadHistory();
  }

  Future<void> push(String title, List<Track> tracks, {int currentIndex = 0}) async {
    state = await ref
        .read(queuePersistenceProvider)
        .pushHistory(title, tracks, currentIndex: currentIndex);
  }

  Future<void> removeAt(int index) async {
    state = await ref.read(queuePersistenceProvider).removeAt(index);
  }
}

/// 本机播放次数（neteaseId → count；增量写入后整体替换触发刷新）
final NotifierProvider<PlayStatsNotifier, Map<int, int>> playStatsProvider =
    NotifierProvider<PlayStatsNotifier, Map<int, int>>(PlayStatsNotifier.new);

class PlayStatsNotifier extends Notifier<Map<int, int>> {
  @override
  Map<int, int> build() => ref.watch(queuePersistenceProvider).loadPlayStats();

  Future<void> increment(int neteaseId) async {
    await ref.read(queuePersistenceProvider).incrementPlay(neteaseId);
    state = ref.read(queuePersistenceProvider).loadPlayStats();
  }
}

/// 当前曲目时长流
final StreamProvider<Duration> durationProvider = StreamProvider<Duration>(
  (Ref ref) => ref
      .watch(audioHandlerProvider)
      .player
      .durationStream
      .map((Duration? d) => d ?? Duration.zero),
);

/// 定时关闭（sleep timer）：remaining 为 null 表示未开启；到点自动暂停
final NotifierProvider<SleepTimerNotifier, Duration?> sleepTimerProvider =
    NotifierProvider<SleepTimerNotifier, Duration?>(SleepTimerNotifier.new);

class SleepTimerNotifier extends Notifier<Duration?> {
  Timer? _tick;

  @override
  Duration? build() => null;

  void start(Duration d) {
    _tick?.cancel();
    state = d;
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      final Duration? left = state;
      if (left == null) {
        t.cancel();
        return;
      }
      if (left <= const Duration(seconds: 1)) {
        t.cancel();
        state = null;
        ref.read(playerProvider.notifier).pause();
      } else {
        state = left - const Duration(seconds: 1);
      }
    });
  }

  void cancel() {
    _tick?.cancel();
    _tick = null;
    state = null;
  }

  void toggle(Duration d) {
    if (state == null) {
      start(d);
    } else {
      cancel();
    }
  }
}

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

/// 单曲高潮点（毫秒）：/song/chorus 首个 startTime（Zephyr-Music 方式）
final FutureProviderFamily<int?, int> chorusStartProvider =
    FutureProvider.family<int?, int>((Ref ref, int songId) async {
  try {
    return await ref.read(neteaseRepositoryProvider).chorusStartMs(songId);
  } catch (_) {
    return null; // 无高潮点数据 / 接口异常：进度条不显示白点
  }
});

/// 当前曲目的高潮点（null = 无数据不显示）
final Provider<int?> currentChorusStartProvider = Provider<int?>((Ref ref) {
  final int? songId = ref.watch(
      playerProvider.select((PlayerState s) => s.currentTrack?.neteaseId));
  if (songId == null || songId <= 0) return null;
  return ref.watch(chorusStartProvider(songId)).valueOrNull;
});

class PlayerNotifier extends Notifier<PlayerState> {
  late MingAudioHandler _handler;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int>? _indexSub;
  StreamSubscription<AppProcessingState>? _processingSub;
  final Random _random = Random();

  /// 队列/下标变更落盘节流定时器
  Timer? _persistDebounce;

  /// 当前曲目播放计次/听歌打卡（每秒 tick，有效播放计时）
  Timer? _playTickTimer;
  int? _statSongId;

  /// 当前曲目已累计的有效播放秒数（暂停不计时）
  int _playedSeconds = 0;

  /// 打卡状态：_scrobbleSent = 已触发（含补报）；_scrobbleDone = 上报完成
  bool _scrobbleSent = false;
  bool _scrobbleDone = false;

  /// 首次 build() 返回前 Riverpod 禁止读写 this.state（抛
  /// "Tried to read the state of an uninitialized provider"）。
  /// 内核流的当前值可能在 build 返回前经微任务送达（BehaviorSubject
  /// 回放），监听回调必须用本标志位挡住这些早期事件。
  bool _ready = false;

  /// 最近一次已生效的状态：依赖变化导致重建时恢复现场，避免 UI 跳变
  PlayerState? _lastState;

  /// 播放直链内存缓存（neteaseId → url），队列重播免二次请求
  final Map<int, SongUrlInfo> _urlCache = <int, SongUrlInfo>{};

  /// 预加载下一首的防抖定时器（快速切歌不重复预热）
  Timer? _preloadTimer;

  /// 私人漫游补歌防并发标志（需求：对齐 Zephyr-Music —— FM 队列临近
  /// 队尾自动再拉 /personal_fm 追加，避免同一次切歌触发多次批量拉取）
  bool _fmReplenishing = false;

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
      // 切歌后同步通知栏红心状态（需求：通知栏增加红心）
      _syncNotificationLike();
      // 需求「只需播放一首缓存一首」：仅在实际开播的曲目上后台落盘
      unawaited(_cacheCurrentTrack());
      // 需求：私人漫游临近队尾自动补歌（对齐 Zephyr-Music）
      unawaited(_maybeReplenishFm());
    });
    _processingSub = _handler.player.processingStateStream
        .map(_mapProcessing)
        .distinct()
        .listen((AppProcessingState ps) {
      if (!_ready) return;
      state = state.copyWith(processing: ps);
    });

    ref.onDispose(() {
      _ready = false; // 销毁后到达的微任务/回调一律静默
      _playingSub?.cancel();
      _indexSub?.cancel();
      _processingSub?.cancel();
      _persistDebounce?.cancel();
      _playTickTimer?.cancel();
      _preloadTimer?.cancel();
    });

    // 通知栏的上一首/下一首交给本 Notifier，保证洗牌/循环逻辑一致
    _handler.setSkipHandlers(onNext: next, onPrevious: previous);

    // 需求：通知栏红心 —— 注入 toggleLike 回调，喜欢状态变化时同步图标
    _handler.setLikeHandler(() async {
      final Track? track = state.currentTrack;
      final int? songId = track?.neteaseId;
      if (songId == null || songId <= 0) return;
      await ref.read(authProvider.notifier).toggleLikeSong(songId);
    });
    ref.listen<AuthState>(authProvider, (AuthState? _, AuthState __) {
      _syncNotificationLike();
    });
    // ⚠️ build() 返回前 Riverpod 尚未写入 _state，此处任何 state 读取都会抛
    // 「Tried to read the state of an uninitialized provider」（荣耀 LRA-AL00
    // 每次启动必现的错误页根因）。首次同步延后到 build 完成后的微任务执行，
    // 届时 state 已就绪；若期间 provider 被销毁，_ready 防护会静默跳过。
    scheduleMicrotask(_syncNotificationLike);

    // ⚠️ 必须返回全新构造的初始值，绝不能 return state ——
    // 首次构建时 state 尚未初始化，读取即抛 StateError（2026-10 启动崩溃根因）。
    // 首次返回默认空状态；重建时恢复最近状态保持连续性。
    final PlayerState initial = _lastState ?? const PlayerState();
    _ready = true;
    return initial;
  }

  // ------------------------------------------------------------ 通知栏红心

  /// 将当前曲目的喜欢状态同步到通知栏（空心⇄实心）
  ///
  /// 仅在 build 完成后允许执行：build 期间（_ready=false）state 尚未初始化，
  /// 读取即抛 StateError。authProvider 若在本 build 内首次初始化，其状态
  /// 变更会同步触发 ref.listen 注册的 listener，此防护负责拦下该路径。
  void _syncNotificationLike() {
    if (!_ready) return;
    final Track? track = state.currentTrack;
    final int? songId = track?.neteaseId;
    final bool liked = songId != null &&
        songId > 0 &&
        ref.read(authProvider).likedIds.contains(songId);
    _handler.setLiked(liked);
  }

  // ------------------------------------------------------- 播放即缓存

  /// 需求「只需播放一首缓存一首」：仅对**实际开播**的曲目后台落盘。
  /// 旧实现在队列解析（resolveTracks）时对整个队列批量预缓存 —— 装载一个
  /// 大歌单即缓存全部曲目，占用暴涨；现改为开播触发，队列解析不再写盘。
  /// 落盘完成同时写入展示元信息（歌名/歌手/封面，缓存列表页与歌名着色用）。
  Future<void> _cacheCurrentTrack() async {
    if (!_ready) return;
    if (!ref.read(listenCacheProvider)) return;
    final Track? track = state.currentTrack;
    final int? id = track?.neteaseId;
    if (id == null || id <= 0) return;
    final String src = track!.source;
    if (src.isEmpty || !src.startsWith('http')) return; // 本地/已缓存路径
    try {
      final SongCacheService cache = ref.read(songCacheProvider);
      final String level = ref.read(audioQualityProvider).apiValue;
      final String? cached = await cache.cachedPathFor(id, level);
      if (cached != null && cached.isNotEmpty) return; // 已缓存
      final bool ok = await cache.download(id, level, src);
      if (ok) {
        unawaited(cache.saveEntryMeta(
          id,
          level,
          title: track.title,
          artist: track.artist,
          cover: track.cover ?? '',
        ));
        // 缓存列表/歌名着色刷新
        refreshCacheProviders(ref);
      }
    } catch (_) {
      // 缓存失败不影响播放
    }
  }

  // ------------------------------------------------------------ 持久化

  /// 队列变更落盘（500ms 节流，切歌/增删共用）
  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 500), () {
      final PlayerState s = state;
      if (!s.loaded) return;
      ref
          .read(queuePersistenceProvider)
          .saveQueueState(s.queue, s.index, s.queueTitle);
    });
  }

  /// 启动恢复（需求：退出重进后自动刷新当前播放歌单的播放 URL ——
  /// 直链约 20 分钟过期，落盘只存歌曲 id）：
  ///  1. 先用占位曲目立即回填 UI（不阻塞首帧）；
  ///  2. 后台经 /song/detail 批量补全元数据（200/批）；
  ///  3. 静默批量重新解析直链（缓存命中直接用本地文件）；
  ///  4. 预加载下一首。全程不自动播放；失败降级为播放时重解析。
  Future<void> restoreQueue() async {
    final saved = ref.read(queuePersistenceProvider).loadQueueState();
    if (saved == null || state.loaded) return;
    final List<Track> initial = saved.queue;
    state = state.copyWith(
      queue: initial,
      index: saved.index,
      queueTitle: saved.queueTitle,
      loaded: true,
      processing: AppProcessingState.idle,
      // 需求：私人漫游队列跨启动恢复后仍自动补歌（按队列名回推标记）
      isFm: saved.queueTitle == '私人漫游',
    );
    if (!saved.hasNeteaseIds) return; // 纯本地/自定义队列：无需刷新

    // ---- 1) 批量补全元数据（离线时保留占位，播放时经 requeue 重试）
    final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
    final List<int> ids = <int>[
      for (final Track t in initial)
        if (t.neteaseId != null && t.neteaseId! > 0) t.neteaseId!,
    ];
    if (ids.isNotEmpty) {
      try {
        final Map<int, Song> detailById = <int, Song>{};
        const int chunkSize = 200;
        for (int i = 0; i < ids.length; i += chunkSize) {
          final List<int> chunk =
              ids.sublist(i, (i + chunkSize).clamp(0, ids.length));
          for (final Song s in await repo.songDetails(chunk)) {
            detailById[s.id] = s;
          }
        }
        if (detailById.isNotEmpty) {
          // 按占位标记合并（而非整体替换）：期间用户可能已装载新队列，
          // 仅把仍处于「加载中…」占位的曲目补全，其余不动。
          final List<Track> current = state.queue;
          final List<Track> merged = <Track>[
            for (final Track t in current)
              (t.neteaseId != null && t.title == '加载中…'
                      ? detailById[t.neteaseId]?.toTrack()
                      : null) ??
                  t,
          ];
          state = state.copyWith(
            queue: merged,
            index: state.index.clamp(0, merged.length - 1),
          );
        }
      } catch (e) {
        debugPrint('restoreQueue: 补全元数据失败（离线？）：$e');
      }
    }

    // ---- 2) 自动刷新直链（需求核心）：静默批量重新解析（含缓存命中）
    try {
      final List<Track> current = state.queue;
      final List<Track> resolved = await resolveTracks(current);
      if (!identical(state.queue, current) || resolved.isEmpty) return;
      final Map<int, Track> byId = <int, Track>{
        for (final Track t in resolved)
          if (t.neteaseId != null) t.neteaseId!: t,
      };
      // 不可解析（VIP 灰曲/离线）的保留原曲目避免丢队列
      final List<Track> merged = <Track>[
        for (final Track t in current) byId[t.neteaseId] ?? t,
      ];
      state = state.copyWith(
        queue: merged,
        index: state.index.clamp(0, merged.length - 1),
      );
      _schedulePersist();
    } catch (e) {
      debugPrint('restoreQueue: 直链刷新失败（播放时会自动重试）：$e');
    }

    // ---- 3) 预加载下一首
    _schedulePreload();
  }

  // ------------------------------------------------------------ 播放统计

  /// 歌曲打卡与上报（需求：对齐 Zephyr-Music）：
  ///  - 每秒 tick 累计**有效播放时长**（暂停不计时，切歌即中断）；
  ///  - 10s：本机播放计次（听歌排行本地统计）；
  ///  - ≥30s：听歌打卡上报 `/scrobble?id&sourceid&time=实际秒数`
  ///   （登录后；每曲至多一次；旧实现固定传 30 且暂停也在计时，
  ///    现改为真实有效时长，与网易云客户端行为一致）；
  ///  - 切歌时若已达 30s 但尚未上报，立即补报。
  void _schedulePlayStat(Track track) {
    final int? songId = track.neteaseId;
    // 切歌：上一曲已达门槛未上报的立即补报
    _flushScrobbleIfNeeded();
    _playTickTimer?.cancel();
    _statSongId = songId;
    _playedSeconds = 0;
    _scrobbleDone = false;
    _scrobbleSent = false;
    if (songId == null) return;
    _playTickTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_statSongId != songId) return; // 已切歌
      // 暂停不累计有效播放时长（对齐网易云/Zephyr 语义）
      if (!_handler.player.playing) return;
      _playedSeconds++;
      if (_playedSeconds == kPlayCountThreshold) {
        ref.read(playStatsProvider.notifier).increment(songId);
      }
      if (_playedSeconds >= kScrobbleThreshold && !_scrobbleSent) {
        _scrobbleSent = true;
        await _scrobble(songId, _playedSeconds);
      }
    });
  }

  /// 本机计次门槛（秒）
  static const int kPlayCountThreshold = 10;

  /// 听歌打卡门槛（秒，对齐网易云客户端/Zephyr）
  static const int kScrobbleThreshold = 30;

  /// 切歌/销毁前补报：已达门槛但 tick 尚未触发上报的场景
  void _flushScrobbleIfNeeded() {
    final int? songId = _statSongId;
    if (songId == null || _scrobbleDone || _scrobbleSent) return;
    if (_playedSeconds < kScrobbleThreshold) return;
    _scrobbleSent = true;
    unawaited(_scrobble(songId, _playedSeconds));
  }

  /// 听歌打卡上报（登录后才上报；失败静默不影响播放）
  Future<void> _scrobble(int songId, int playedSeconds) async {
    _scrobbleDone = true;
    try {
      final bool loggedIn = ref.read(authProvider).loggedIn;
      if (!loggedIn) return;
      await ref.read(neteaseRepositoryProvider).scrobble(
            songId,
            0,
            playedSeconds,
          );
    } catch (_) {
      // 打卡失败静默：不影响播放
    }
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
  ///  2. 装载内核队列并从 [startIndex] 开始播放；
  ///  3. [isFm] 私人漫游标记：临近队尾自动补歌（对齐 Zephyr-Music）。
  ///
  /// 第十三批需求「来源污染」修复：queueTitle/isFm 不再在解析前预写 ——
  /// 旧流程先置「每日推荐」再解析，解析失败（全 VIP/网络抖动）时队列
  /// 仍是旧队列而顶部来源已变成新名，播放页顶栏来源与实际内容不符；
  /// 现在延迟到 loadQueue 成功后一并写入，失败时来源保持不变。
  Future<void> playSongs(
    List<Track> tracks, {
    int startIndex = 0,
    String? queueTitle,
    bool isFm = false,
  }) async {
    if (tracks.isEmpty) return;
    final int safeStart = startIndex.clamp(0, tracks.length - 1);
    state = state.copyWith(
      processing: AppProcessingState.loading,
      clearError: true,
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
      // 需求：无网播放时通知栏提示「已跳过未缓存歌曲」——
      // 解析被剔除的曲目数 > 0 且当前处于无网环境时，发系统通知告知用户
      // （通知栏可见，应用后台/熄屏播歌也能收到原因说明）
      final int dropped = tracks.length - resolved.length;
      if (dropped > 0) {
        final bool offline = !(await PlatformActions.isNetworkAvailable());
        if (offline) {
          unawaited(PlatformActions.postStatusNotice(
            title: 'MingMusic',
            text: '当前无网环境已跳过 $dropped 首未缓存歌曲',
          ));
        }
      }
      // 起点 id 对齐：解析过程可能剔除灰曲，按下标近似定位
      final Track wanted = tracks[safeStart];
      int startIdx = resolved.indexWhere((Track t) => t.id == wanted.id);
      if (startIdx < 0) {
        startIdx = safeStart.clamp(0, resolved.length - 1);
      }
      // 装载新队列前：旧队列入历史快照（去重，最多 3 个；
      // 记录当前播放位置供「继续播放」显示与恢复）
      if (state.loaded && state.hasQueue) {
        unawaited(ref
            .read(queueHistoryProvider.notifier)
            .push(state.queueTitle ?? '播放列表', state.queue,
                currentIndex: state.index));
      }
      state = state.copyWith(
        queue: resolved,
        index: startIdx,
        loaded: true,
        processing: AppProcessingState.buffering,
        // 装载成功后才写入来源（防污染，见方法注释）
        queueTitle: queueTitle,
        clearQueueTitle: queueTitle == null,
        isFm: isFm,
      );
      await _handler.loadQueue(resolved, initialIndex: startIdx);
      await _handler.play();
      _schedulePlayStat(resolved[startIdx]);
      _schedulePersist();
      _schedulePreload();
      // FM 首批装载后立即检查是否需要预取（首批仅 3 首）
      unawaited(_maybeReplenishFm());
    } catch (e) {
      state = state.copyWith(
        processing: AppProcessingState.idle,
        error: '加载播放列表失败：$e',
      );
    }
  }

  /// 切换音质：全队列按新音质重新解析直链，保留当前进度续播。
  /// 返回 null 表示成功，否则为错误信息。
  Future<String?> switchQuality(AudioQuality quality) async {
    if (!state.hasQueue) return '当前没有播放队列';
    final AudioQuality current = ref.read(audioQualityProvider);
    if (quality == current) return null;

    final Duration pos = _handler.player.position;
    final bool wasPlaying = state.playing;
    final List<Track> queue = state.queue;
    final int index = state.index.clamp(0, queue.length - 1);

    // 音质变化必须绕过直链缓存重新解析
    _urlCache.clear();
    state = state.copyWith(processing: AppProcessingState.loading);
    try {
      final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
      final List<int> ids = <int>[
        for (final Track t in queue)
          if (t.neteaseId != null) t.neteaseId!,
      ];
      final Map<int, SongUrlInfo> urlById = <int, SongUrlInfo>{};
      if (ids.isNotEmpty) {
        for (final SongUrlInfo u
            in await repo.songUrls(ids, level: quality.apiValue)) {
          urlById[u.id] = u;
        }
      }
      final List<Track> rebuilt = <Track>[
        for (final Track t in queue)
          if (t.neteaseId == null)
            t
          else if (urlById[t.neteaseId!]?.playable ?? false)
            t.copyWith(source: urlById[t.neteaseId!]!.url)
          else
            t, // 新音质拿不到链接（如未登录无损）：保留原曲目避免丢队列
      ];
      // 拿到新直链的曲目进缓存
      urlById.forEach((int id, SongUrlInfo u) => _urlCache[id] = u);

      int newIndex = index;
      final Track target = queue[index];
      final int found = rebuilt.indexWhere((Track t) => t.id == target.id);
      if (found >= 0) newIndex = found;

      ref.read(audioQualityProvider.notifier).set(quality);
      state = state.copyWith(
        queue: rebuilt,
        index: newIndex,
        processing: AppProcessingState.buffering,
      );
      await _handler.loadQueue(rebuilt, initialIndex: newIndex);
      // 保留进度续播
      if (pos > Duration.zero) await _handler.seek(pos);
      if (wasPlaying) {
        await _handler.play();
      }
      _schedulePersist();
      return null;
    } catch (e) {
      state = state.copyWith(
        processing: AppProcessingState.idle,
        error: '切换音质失败：$e',
      );
      return '$e';
    }
  }

  /// 长按菜单「下一首播放」（需求）：解析后插入当前曲目之后，
  /// **不打断当前播放**（保留进度与播放状态）。
  /// 修复「插队时短暂停顿」：不再 loadQueue 重建整个内核队列（那会
  /// 重新初始化当前音轨），改用内核增量插入/移除（insertAudioSource）。
  /// 返回 null 表示成功，否则为错误信息。
  Future<String?> insertNext(Track track) async {
    if (!state.hasQueue) return '当前没有播放队列';
    try {
      List<Track> resolved = await resolveTracks(<Track>[track]);
      if (resolved.isEmpty) resolved = <Track>[track]; // 离线也允许入队，播放时再解析
      final Track target = resolved.first;
      final List<Track> q = List<Track>.of(state.queue);
      final int existing = q.indexWhere((Track t) => t.id == target.id);
      int index = state.index;
      if (existing >= 0) {
        if (existing == index + 1) return null; // 已是下一首：幂等
        // 增量移除旧位置（当前播放曲目不可移除：放弃去重，仅插入）
        if (await _handler.removeTrackAt(existing)) {
          q.removeAt(existing);
          if (existing < index) index--;
        }
      }
      q.insert((index + 1).clamp(0, q.length), target);
      state = state.copyWith(queue: q, index: index);
      await _handler.insertTrackNext(target, atIndex: index + 1);
      _schedulePersist();
      _schedulePreload();
      return null;
    } catch (e) {
      return '插入失败：$e';
    }
  }

  /// 相似歌曲插播：解析后插入当前曲目之后并立即切换播放。
  /// 返回 null 表示成功，否则为错误信息。
  Future<String?> playSimilarNext(Track track) async {
    if (!state.hasQueue) return '当前没有播放队列';
    try {
      final List<Track> resolved = await resolveTracks(<Track>[track]);
      if (resolved.isEmpty) return '该歌曲暂不可播放（VIP 或版权受限）';
      final Track target = resolved.first;
      final List<Track> q = List<Track>.of(state.queue);
      // 去重：队列已存在则先移除（同步校正下标）
      final int existing = q.indexWhere((Track t) => t.id == target.id);
      int index = state.index;
      if (existing >= 0) {
        q.removeAt(existing);
        if (existing < index) index--;
      }
      final int at = (index + 1).clamp(0, q.length);
      q.insert(at, target);
      state = state.copyWith(queue: q, index: index);
      await _handler.loadQueue(q, initialIndex: at);
      await _handler.play();
      _schedulePlayStat(target);
      _schedulePersist();
      _schedulePreload();
      return null;
    } catch (e) {
      return '插播失败：$e';
    }
  }

  /// 批量解析网易云直链：命中内存缓存直接复用，未命中的批量请求。
  /// 不可播（VIP 拿不到链接）的曲目剔除，试听片段保留（freeTrial）。
  ///
  /// 需求「离线可播」：直链未解析时**先查磁盘缓存**，命中直接改用本地
  /// 文件并跳过网络请求 —— 断网时旧实现强制请求 /song/url 失败，导致
  /// 已缓存歌曲也无法播放。
  /// 需求「只缓存播放的歌」：解析不再触发预下载（开播时才落盘）。
  /// 直链批量请求失败（断网/接口异常）不再整体抛出：返回已命中的部分，
  /// 播放队列/离线场景保留可用曲目。
  Future<List<Track>> resolveTracks(List<Track> tracks) async {
    final SongCacheService cache = ref.read(songCacheProvider);
    final bool cacheOn = ref.read(listenCacheProvider);
    final String level = ref.read(audioQualityProvider).apiValue;

    final Map<int, Track> resolvedById = <int, Track>{};
    final Map<int, Track> pending = <int, Track>{};

    for (final Track t in tracks) {
      final int? nid = t.neteaseId;
      if (nid == null || nid <= 0) continue; // 非网易云（自定义直链）：直接可用
      // 本地文件源直接放行（缓存音乐列表页点播：路径已验证存在，
      // 不再走网络解析 —— 离线可用且不受当前音质档位影响）
      if (t.source.isNotEmpty && !t.source.startsWith('http')) {
        resolvedById[nid] = t;
        continue;
      }
      final SongUrlInfo? cached = _urlCache[nid];
      if (cached != null) {
        if (cached.playable) {
          resolvedById[nid] = await _withCacheSource(t, cached);
        }
        continue; // 缓存命中但不可播：剔除（VIP 灰曲）
      }
      if (cacheOn) {
        try {
          final String? path = await cache.cachedPathFor(nid, level);
          if (path != null && path.isNotEmpty) {
            resolvedById[nid] = t.copyWith(source: path);
            continue;
          }
        } catch (_) {}
      }
      pending[nid] = t;
    }

    if (pending.isNotEmpty) {
      try {
        final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
        final List<SongUrlInfo> urls =
            await repo.songUrls(pending.keys.toList(), level: level);
        for (final SongUrlInfo u in urls) {
          final Track? t = pending[u.id];
          if (t == null) continue;
          _urlCache[u.id] = u;
          if (u.playable) {
            resolvedById[u.id] = await _withCacheSource(t, u);
          }
        }
      } catch (e) {
        debugPrint('resolveTracks: 直链批量解析失败（离线？）：$e');
      }
    }

    // 按入参顺序组装（保持队列顺序稳定），解析失败的曲目剔除
    final List<Track> out = <Track>[];
    for (final Track t in tracks) {
      final int? nid = t.neteaseId;
      if (nid == null || nid <= 0) {
        out.add(t);
      } else {
        final Track? r = resolvedById[nid];
        if (r != null) out.add(r);
      }
    }
    return out;
  }

  /// 缓存感知的播放源选择：
  ///  - 边听边缓存开启：磁盘命中 → 本地文件（秒开）；
  ///  - 未命中：网络 URL（落盘延后到开播时，见 _cacheCurrentTrack）；
  ///  - 关闭：直接用网络 URL。
  Future<Track> _withCacheSource(Track t, SongUrlInfo u) async {
    final int id = t.neteaseId!;
    if (!ref.read(listenCacheProvider)) return t.copyWith(source: u.url);
    try {
      final SongCacheService cache = ref.read(songCacheProvider);
      final String level = ref.read(audioQualityProvider).apiValue;
      final String? path = await cache.cachedPathFor(id, level);
      if (path != null && path.isNotEmpty) {
        return t.copyWith(source: path);
      }
    } catch (_) {
      // 缓存层异常不影响播放
    }
    return t.copyWith(source: u.url);
  }

  // ------------------------------------------------------------ 预加载

  /// 预加载下一首（需求：默认开启）：切歌后延迟 2.5s 触发，快速连切不重复预热
  void _schedulePreload() {
    _preloadTimer?.cancel();
    _preloadTimer = Timer(const Duration(milliseconds: 2500), () {
      unawaited(_preloadNextTrack());
    });
  }

  Future<void> _preloadNextTrack() async {
    if (!ref.read(preloadNextProvider)) return;
    if (!state.hasQueue || state.queue.length <= 1) return;
    // 随机/单曲循环的下一首不可预测，跳过
    if (state.shuffle || state.repeat == RepeatMode.one) return;
    final int nextIdx = (state.index + 1) % state.queue.length;
    final Track next = state.queue[nextIdx];
    final int? id = next.neteaseId;
    if (id == null || id <= 0) return;
    final String level = ref.read(audioQualityProvider).apiValue;
    final SongCacheService cache = ref.read(songCacheProvider);
    final String key = cache.keyFor(id, level);
    if (!cache.shouldPreload(key)) return;
    cache.markPreloaded(key);
    try {
      SongUrlInfo? info = _urlCache[id];
      info ??= await _resolveSingleUrl(id);
      if (info == null || !info.playable) return;
      if (ref.read(listenCacheProvider)) {
        final String? cached = await cache.cachedPathFor(id, level);
        if (cached != null) return; // 已缓存，无需预载
        await cache.download(id, level, info.url);
      } else {
        // 缓存关闭：退化为临时播放器预热（提前建立连接与首段缓冲）
        await cache.warmUp(info.url);
      }
    } catch (_) {
      // 预加载失败静默：不影响播放
    }
  }

  /// 单曲直链解析（预加载用；不写曲目，仅补充 _urlCache）
  Future<SongUrlInfo?> _resolveSingleUrl(int id) async {
    try {
      final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
      final String level = ref.read(audioQualityProvider).apiValue;
      final List<SongUrlInfo> urls =
          await repo.songUrls(<int>[id], level: level);
      for (final SongUrlInfo u in urls) {
        _urlCache[u.id] = u;
        if (u.playable) return u;
      }
    } catch (_) {}
    return null;
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
      _schedulePlayStat(next[nextIndex]);
    }
    _schedulePersist();
  }

  /// 队列拖动排序（播放列表弹窗拖动按键）。
  /// 使用 ReorderableListView.onReorderItem：newIndex 已按「移除旧项」
  /// 语义校正过，无需再做 -1 修正；
  /// 当前曲目位置变化时重建内核队列并保留进度续播。
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (!state.hasQueue) return;
    if (oldIndex < 0 || oldIndex >= state.queue.length) return;
    final List<Track> q = List<Track>.of(state.queue);
    final Track moved = q.removeAt(oldIndex);
    final int target = newIndex.clamp(0, q.length);
    q.insert(target, moved);

    int idx = state.index;
    if (oldIndex == idx) {
      idx = target;
    } else if (oldIndex < idx && target >= idx) {
      idx -= 1;
    } else if (oldIndex > idx && target <= idx) {
      idx += 1;
    }
    state = state.copyWith(queue: q, index: idx);

    // 内核队列顺序必须与 UI 一致：重建队列，保留当前进度与播放状态
    final Duration pos = _handler.player.position;
    final bool wasPlaying = state.playing;
    await _handler.loadQueue(q, initialIndex: idx.clamp(0, q.length - 1));
    if (pos > Duration.zero) await _handler.seek(pos);
    if (wasPlaying) await _handler.play();
    _schedulePersist();
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
      isFm: false,
    );
    await ref.read(queuePersistenceProvider).clearQueueState();
  }

  /// 私人漫游（需求：对齐 Zephyr-Music 的处理方式 ——
  /// /personal_fm 每次只返回 3 首，旧实现直接把 3 首当固定队列，
  /// 播完三首就停；现在首装载即带 isFm 标记，配合 _maybeReplenishFm
  /// 在临近队尾自动再拉一批追加，在线状态下漫游永不播完）。
  /// 返回错误文案（null 成功）。
  Future<String?> startPersonalFm() async {
    state = state.copyWith(
        processing: AppProcessingState.loading, clearError: true);
    try {
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).personalFm();
      if (songs.isEmpty) {
        state = state.copyWith(processing: AppProcessingState.idle);
        return '私人漫游暂无可用歌曲';
      }
      await playSongs(
        <Track>[for (final Song s in songs) s.toTrack()],
        queueTitle: '私人漫游',
        isFm: true,
      );
      return null;
    } catch (e) {
      state = state.copyWith(processing: AppProcessingState.idle);
      return '进入私人漫游失败：$e';
    }
  }

  /// FM 队列补歌（需求：对齐 Zephyr-Music）：
  ///  - 仅 isFm 队列触发；当前曲目是最后一首时再拉一批 /personal_fm；
  ///  - 去重（按 neteaseId，FM 批次间偶有重叠）；
  ///  - 增量追加到内核队尾（当前音轨不重载，播放无感）；
  ///  - 失败静默（下首切歌时重新触发），防并发标志避免重复拉取。
  Future<void> _maybeReplenishFm() async {
    if (!state.isFm || !state.hasQueue) return;
    if (_fmReplenishing) return;
    // 临近队尾（当前曲目是最后一首 / 仅剩一首缓冲）才补
    if (state.index < state.queue.length - 1) return;
    _fmReplenishing = true;
    try {
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).personalFm();
      if (!state.isFm) return; // 期间队列已被替换
      final Set<int> existing = <int>{
        for (final Track t in state.queue)
          if (t.neteaseId != null) t.neteaseId!,
      };
      final List<Track> fresh = <Track>[
        for (final Song s in songs)
          if (!existing.contains(s.id)) s.toTrack(),
      ];
      if (fresh.isEmpty) return;
      final List<Track> resolved = await resolveTracks(fresh);
      if (resolved.isEmpty || !state.isFm) return;
      await _handler.appendTracks(resolved);
      state = state.copyWith(queue: <Track>[...state.queue, ...resolved]);
      _schedulePersist();
    } catch (_) {
      // 补歌失败静默：下次切歌到队尾时重新触发
    } finally {
      _fmReplenishing = false;
    }
  }

  /// 心动模式漫游：优先 /playmode/intelligence/list（登录态个性化），
  /// 失败回退 /simi/song。返回错误文案（null 成功）
  Future<String?> startRoaming() async {
    final Track? current = state.currentTrack;
    final int? songId = current?.neteaseId;
    if (songId == null || songId == 0) return '当前没有可漫游的歌曲';
    state = state.copyWith(processing: AppProcessingState.loading);
    try {
      final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
      List<Song> songs = const <Song>[];
      try {
        songs = await repo.intelligenceList(songId, 0);
      } catch (_) {
        // 个性化接口失败 → 相似歌曲
      }
      if (songs.isEmpty) {
        songs = await repo.simiSongs(songId);
      }
      if (songs.isEmpty) {
        state = state.copyWith(processing: AppProcessingState.idle);
        return '暂无相似歌曲可漫游';
      }
      // 当前曲放首位，后续为相似歌曲
      final List<Track> tracks = <Track>[
        current!,
        ...songs.map((Song s) => s.toTrack())
      ];
      state = state.copyWith(processing: AppProcessingState.idle);
      await playSongs(tracks, startIndex: 0, queueTitle: '心动模式 · 相似歌曲漫游');
      return null;
    } catch (e) {
      state = state.copyWith(processing: AppProcessingState.idle);
      return '漫游失败：$e';
    }
  }

  /// 插播相似歌曲：取一首当前曲目的相似歌曲插入下一首并立即播放
  Future<String?> playNextSimilar() async {
    final Track? current = state.currentTrack;
    final int? songId = current?.neteaseId;
    if (songId == null || songId == 0) return '当前没有可插播的歌曲';
    try {
      final List<Song> songs =
          await ref.read(neteaseRepositoryProvider).simiSongs(songId);
      if (songs.isEmpty) return '暂无相似歌曲';
      return await playSimilarNext(songs.first.toTrack());
    } catch (e) {
      return '插播失败：$e';
    }
  }

  /// 直接暂停（定时关闭用）
  Future<void> pause() => _handler.pause();

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
    // 目标曲目直链缺失（恢复队列/离线降级场景）：单曲按需解析 ——
    // 缓存命中（离线）得本地路径可播；彻底失败则提示，不再让内核空源报错
    if (state.queue[safe].needsUrlResolve) {
      final List<Track> one = await resolveTracks(<Track>[state.queue[safe]]);
      if (one.isNotEmpty) {
        final List<Track> q = List<Track>.of(state.queue);
        q[safe] = one.first;
        state = state.copyWith(queue: q);
      }
      if (state.queue[safe].needsUrlResolve) {
        state = state.copyWith(error: '该歌曲暂无法播放（离线且未缓存，联网后重试）');
        return;
      }
    }
    state = state.copyWith(index: safe);
    await _handler.player.seek(Duration.zero, index: safe);
    if (!state.playing) {
      await _handler.play();
    }
    _schedulePlayStat(state.queue[safe]);
    _schedulePersist();
    _schedulePreload();
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
