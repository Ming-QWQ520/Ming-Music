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
import 'dart:io';
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
import '../../comments/providers/comments_providers.dart'
    show songCommentCountProvider;
import 'lyrics_providers.dart' show lyricDataProvider;
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

  Future<void> push(String title, List<Track> tracks,
      {int currentIndex = 0}) async {
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

/// 歌曲红心数（需求第二十一批：/song/red/count?id=，数字显示在红心
/// 图标角标上；格式化在 UI 层完成；失败返回 0 不显示角标）
final FutureProviderFamily<int, int> songRedCountProvider =
    FutureProvider.family<int, int>((Ref ref, int songId) async {
  try {
    return await ref.read(neteaseRepositoryProvider).songRedCount(songId);
  } catch (_) {
    return 0;
  }
});

/// 曲目真实音质元数据（neteaseId → 最近一次 /song/url/v1 响应元数据：
/// level 实际下发档位 / br 实际码率 / sr 实际采样率）。
///
/// 需求：播放设置「音质」项显示当前播放歌曲的真实频率与真实品质 ——
/// 请求档位因权限回落时（如未登录请求无损实际拿到极高），响应里的
/// level/sr 才是真实值，选择器里的档位只是请求值。
final NotifierProvider<SongMetaNotifier, Map<int, SongUrlInfo>>
    songMetaProvider =
    NotifierProvider<SongMetaNotifier, Map<int, SongUrlInfo>>(
        SongMetaNotifier.new);

class SongMetaNotifier extends Notifier<Map<int, SongUrlInfo>> {
  @override
  Map<int, SongUrlInfo> build() => const <int, SongUrlInfo>{};

  void upsertAll(Map<int, SongUrlInfo> meta) {
    if (meta.isEmpty) return;
    state = <int, SongUrlInfo>{...state, ...meta};
  }
}

/// 当前播放曲目的真实音质元数据（null = 尚未解析 / 本地或自定义曲目）
final Provider<SongUrlInfo?> currentTrackUrlMetaProvider =
    Provider<SongUrlInfo?>((Ref ref) {
  final int? nid = ref.watch(
      playerProvider.select((PlayerState s) => s.currentTrack?.neteaseId));
  if (nid == null || nid <= 0) return null;
  return ref
      .watch(songMetaProvider.select((Map<int, SongUrlInfo> m) => m[nid]));
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

  /// 播放直链内存缓存（neteaseId → url），队列重播免二次请求。
  /// 配套 [_urlCacheAt] 时间戳：网易直链实测约 20 分钟过期，超过
  /// [_urlCacheTtl] 视为陈旧重新解析（否则内核播放过期直链报错停摆
  /// ——「有时播完不下一首」「搜索中添加的音乐无法播放」的共因）。
  final Map<int, SongUrlInfo> _urlCache = <int, SongUrlInfo>{};
  final Map<int, DateTime> _urlCacheAt = <int, DateTime>{};

  /// 直链内存缓存有效期（保守取 15 分钟，低于网易直链 20 分钟生命周期）
  static const Duration _urlCacheTtl = Duration(minutes: 15);

  /// 读缓存：超过 TTL 视为陈旧返回 null（并清掉旧条目）
  SongUrlInfo? _cachedUrl(int id) {
    final DateTime? at = _urlCacheAt[id];
    if (at == null) return null;
    if (DateTime.now().difference(at) > _urlCacheTtl) {
      _urlCache.remove(id);
      _urlCacheAt.remove(id);
      return null;
    }
    return _urlCache[id];
  }

  /// 写缓存（登记解析时刻）
  void _storeUrl(int id, SongUrlInfo u) {
    _urlCache[id] = u;
    _urlCacheAt[id] = DateTime.now();
  }

  /// 预加载下一首的防抖定时器（快速切歌不重复预热）
  Timer? _preloadTimer;

  /// 私人漫游补歌防并发标志（需求：对齐 Zephyr-Music —— FM 队列临近
  /// 队尾自动再拉 /personal_fm 追加，避免同一次切歌触发多次批量拉取）
  bool _fmReplenishing = false;

  /// 无网播放失败标记：置位后网络恢复事件到达时自动刷新直链并接续播放
  /// （需求：无网播放再连接网络时无法正常播放）
  bool _networkResumePending = false;

  /// 离线降级前的完整队列（需求第二十一批：无网部分命中时内核只装
  /// 可播子集，完整队列记忆在此，联网恢复后还原并整体重解析 ——
  /// 防止「无网播过一次后队列被永久裁短」）
  List<Track>? _offlineFullQueue;

  /// 网络恢复事件订阅（原生 ConnectivityManager，离线→在线发一次）
  StreamSubscription<dynamic>? _netSub;

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
      // 需求（第二十四批）「歌词出现延迟」根治：曲目切换瞬间即预取
      // 当前曲 + 队列下一曲的歌词（此前歌词在打开播放页/歌词视图时才
      // 首次请求，网络往返全部暴露给用户 —— 现在切歌即拉，打开秒显）
      unawaited(_prefetchLyrics());
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
    // 需求：无网播放失败/中断 → 联网后自动接续。原生只在离线→在线
    // 转变时发一次事件，不打扰正常在线播放。
    _netSub = PlatformActions.networkRestoredStream().listen((_) {
      if (!_ready) return;
      unawaited(_onNetworkRestored());
    });

    ref.onDispose(() {
      _ready = false; // 销毁后到达的微任务/回调一律静默
      _playingSub?.cancel();
      _indexSub?.cancel();
      _processingSub?.cancel();
      _netSub?.cancel();
      _persistDebounce?.cancel();
      _playTickTimer?.cancel();
      _preloadTimer?.cancel();
    });

    // 通知栏的上一首/下一首交给本 Notifier，保证洗牌/循环逻辑一致
    _handler.setSkipHandlers(onNext: next, onPrevious: previous);
    // 音源加载失败自动恢复（第二十八批）：直链过期/离线空源到达播放点
    // 时内核报错停摆 —— 重解析当前曲目续播，解析不出自动跳下一首
    _handler.setRecoveryHandler(_recoverCurrentSource);

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
  /// 落盘元信息写入统一走 _saveCacheMeta（需求第二十二批：
  /// 播放缓存与预加载缓存两条链路一致，避免预载曲目无元信息、
  /// 缓存页退化为「歌曲 id / 元信息未记录」）
  void _saveCacheMeta(Track track, String level) {
    final int? id = track.neteaseId;
    if (id == null || id <= 0) return;
    unawaited(ref.read(songCacheProvider).saveEntryMeta(
          id,
          level,
          title: track.title,
          artist: track.artist,
          // 需求第二十一批：数据缓存列表封面统一 200x200 参数
          cover: SongCacheService.normalizeCover200(track.cover),
        ));
  }

  // ------------------------------------------------------------ 歌词预取

  /// 需求（第二十四批）「歌词出现延迟」：切歌瞬间预取当前曲 + 队列
  /// 下一曲的歌词。lyricDataProvider 是 FutureProvider.family，结果
  /// 自动按歌曲 id 缓存 —— 打开播放页/歌词视图时命中缓存零等待。
  /// 失败静默（打开页面时会自然重试）。
  Future<void> _prefetchLyrics() async {
    final PlayerState s = state;
    final List<int> ids = <int>[
      if (s.currentTrack?.neteaseId case final int cur when cur > 0) cur,
      // 下一曲也一并预取：连续听歌时歌词始终先于用户到达
      if (s.index + 1 < s.queue.length)
        if (s.queue[s.index + 1].neteaseId case final int next when next > 0)
          next,
    ];
    for (final int id in ids) {
      try {
        await ref.read(lyricDataProvider(id).future);
      } catch (_) {
        // 预取失败不阻断：UI 打开时 provider 会重新请求
      }
    }
  }

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
        _saveCacheMeta(track, level);
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
      final List<Track>? full = _offlineFullQueue;
      if (full != null) {
        // 离线降级态：落盘完整队列（按当前播放曲目对齐下标），
        // 避免子集队列被持久化导致联网后曲目丢失
        final Track? cur = s.currentTrack;
        int idx =
            cur == null ? 0 : full.indexWhere((Track t) => t.id == cur.id);
        if (idx < 0) idx = 0;
        ref
            .read(queuePersistenceProvider)
            .saveQueueState(full, idx, s.queueTitle);
        return;
      }
      ref
          .read(queuePersistenceProvider)
          .saveQueueState(s.queue, s.index, s.queueTitle);
    });
  }

  /// 启动恢复（需求：退出重进后自动刷新当前播放歌单的播放 URL ——
  /// 直链约 20 分钟过期，落盘只存歌曲 id）：
  ///  1. 先用落盘元数据立即回填 UI（不阻塞首帧；v3 存档自带真实
  ///     标题/歌手/封面，Mini 条不再显示「加载中…」）；
  ///  2. 后台经 /song/detail 批量补全元数据（v2 旧档占位行；200/批）；
  ///  3. 静默批量重新解析直链（缓存命中直接用本地文件）；
  ///  4. **静默装载播放内核队列（不自动播放）** —— 第十七批修复：
  ///     旧实现只回填 Riverpod 状态、内核 after 重启仍是空队列，
  ///     点击播放 play() 无源可放（名称/封面永不变），媒体会话无
  ///     MediaItem → 通知栏不出现控制栏。装载后通知栏/锁屏立即可控；
  ///  5. 预加载下一首。全程不自动播放；失败降级为播放时重解析。
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
    if (!saved.hasNeteaseIds) {
      // 纯本地/自定义队列：直链就在落盘数据里，直接装载内核
      await _loadKernelIfIdle(initial, saved.index);
      return;
    }

    // ---- 1) 批量补全元数据（离线时保留落盘/占位，联网恢复后自动重拉）
    await _backfillQueueMetadata();

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

    // ---- 3) 静默装载内核（第十七批：通知栏控制栏/点击播放立即可用）
    await _loadKernelIfIdle(state.queue, state.index);

    // ---- 4) 预加载下一首
    _schedulePreload();
  }

  /// 队列占位元数据补全（/song/detail 批量，200/批）：仅替换仍处于
  /// 「加载中…」占位的曲目，其余不动。启动恢复与网络恢复共用
  ///（需求第二十一批：无网进入恢复队列后，联网自动补齐歌名/封面，
  /// 无需用户手动交互）。
  Future<void> _backfillQueueMetadata() async {
    final List<int> ids = <int>[
      for (final Track t in state.queue)
        if (t.neteaseId != null && t.neteaseId! > 0 && t.title == '加载中…')
          t.neteaseId!,
    ];
    if (ids.isEmpty) return;
    try {
      final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
      final Map<int, Song> detailById = <int, Song>{};
      const int chunkSize = 200;
      for (int i = 0; i < ids.length; i += chunkSize) {
        final List<int> chunk =
            ids.sublist(i, (i + chunkSize).clamp(0, ids.length));
        for (final Song s in await repo.songDetails(chunk)) {
          detailById[s.id] = s;
        }
      }
      if (detailById.isEmpty) return;
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
    } catch (e) {
      debugPrint('补全队列元数据失败（离线？）：$e');
    }
  }

  /// 内核空闲（无音源）时静默装载队列：仅当每首曲目直链就绪才装载
  /// （空 source 的曲目会被内核当 asset 路径解析，必须先过滤/重解析）。
  /// 不触发播放，只回填 MediaItem/PlaybackState → 通知栏/锁屏立即可见。
  Future<void> _loadKernelIfIdle(List<Track> queue, int index) async {
    if (queue.isEmpty) return;
    if (_handler.player.audioSources.isNotEmpty) return;
    if (queue.any((Track t) => t.needsUrlResolve)) return; // 播放时再解析
    try {
      await _handler.loadQueue(queue,
          initialIndex: index.clamp(0, queue.length - 1));
      _syncNotificationLike();
    } catch (e) {
      debugPrint('restoreQueue: 内核装载失败（播放时会重试）：$e');
    }
  }

  // ------------------------------------------------------------ 网络接续

  /// 网络恢复：自动接续无网期间失败的播放 + 自动重取元数据（需求）。
  ///
  /// 触发动作：
  ///  - 元数据（歌词/红心数/评论数/高潮点）自动 invalidate 重取 ——
  ///    需求第二十一批：无网播放恢复连接时自动获取封面和歌词等信息，
  ///    不等用户手动交互（封面重试由 CoverImage 自身订阅同一事件）；
  ///  - 存在未解析曲目（无网进入恢复队列场景）→ 静默刷新直链，
  ///    保留进度，不自动播放；
  ///  - 曾因离线播放失败（[_networkResumePending]）→ 刷新直链后
  ///    自动恢复播放；
  ///  - 离线降级队列（[_offlineFullQueue]）→ 还原完整队列整体重解析；
  ///  - 直链存在但内核报错卡死（无网时 URL 失效）→ 刷新当前曲目
  ///    直链重建内核，再接续播放。
  Future<void> _onNetworkRestored() async {
    final bool offline = !(await PlatformActions.isNetworkAvailable());
    if (offline) return; // 事件抖动：实际仍未联网
    // 1) 元数据自动重取（播放中也刷新：无网时打开的歌词/红心数补拉）
    _refreshCurrentMetadata();
    if (state.queue.isEmpty && _offlineFullQueue == null) return;
    if (state.playing) return; // 正常播放中：只补元数据，不打扰
    final bool pending = _networkResumePending;
    _networkResumePending = false;
    final List<Track>? degraded = _offlineFullQueue;
    _offlineFullQueue = null;
    // 2) 离线降级队列还原：完整队列回填 state，按当前曲目对齐下标
    if (degraded != null) {
      final Track? cur = state.currentTrack;
      int idx = cur == null
          ? state.index
          : degraded.indexWhere((Track t) => t.id == cur.id);
      if (idx < 0) idx = state.index.clamp(0, degraded.length - 1);
      state = state.copyWith(queue: degraded, index: idx);
    }
    final bool hasUnresolved = state.queue.any((Track t) => t.needsUrlResolve);
    final bool kernelEmpty = _handler.player.audioSources.isEmpty;
    if (!pending && !hasUnresolved && !kernelEmpty && degraded == null) return;
    try {
      final Duration pos = _handler.player.position;
      // 3) 无网期间留下的占位元数据（歌名/封面）一并补齐
      await _backfillQueueMetadata();
      // 4) 直链刷新 + 内核重装（全部就绪才装载；requeueIfNeeded 内含）
      if (hasUnresolved || degraded != null) {
        await requeueIfNeeded();
      }
      // 5) 全量解析仍不齐（部分灰曲/仍无网）：降级装载可播子集
      if (_handler.player.audioSources.isEmpty &&
          state.queue.any((Track t) => !t.needsUrlResolve)) {
        await _degradeToPlayableSubset();
      }
      if (!state.playing && pending) {
        await _handler.play();
      } else if (!state.playing && pos > Duration.zero) {
        // 仅刷新直链（非失败接续）：保留原进度，不自动播放
        await _handler.seek(pos);
      }
    } catch (e) {
      debugPrint('网络恢复接续失败：$e');
    }
  }

  /// 当前曲目元数据自动重取（需求第二十一批：恢复连接后歌词、红心数、
  /// 评论数、高潮点自动重拉，无需用户手动交互；封面由 CoverImage
  /// 订阅同一事件自行重试）
  void _refreshCurrentMetadata() {
    final int? songId = state.currentTrack?.neteaseId;
    if (songId == null || songId <= 0) return;
    ref.invalidate(lyricDataProvider(songId));
    ref.invalidate(songRedCountProvider(songId));
    ref.invalidate(songCommentCountProvider(songId));
    ref.invalidate(chorusStartProvider(songId));
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
    bool autoPlay = true,
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
        unawaited(ref.read(queueHistoryProvider.notifier).push(
            state.queueTitle ?? '播放列表', state.queue,
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
      // autoPlay=false：一起听采纳房间队列等场景 —— 只装载不开播，
      // 等对方 GOTO/加入对齐命令选歌，避免抢播错歌
      if (autoPlay) {
        await _handler.play();
      }
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
    _urlCacheAt.clear();
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
      urlById.forEach(_storeUrl);
      // 同步真实音质元数据（需求：音质项展示真实频率/真实品质）
      ref.read(songMetaProvider.notifier).upsertAll(urlById);

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
      final List<Track> resolved = await resolveTracks(<Track>[track]);
      final Track target;
      if (resolved.isEmpty) {
        // ⚠️ 修复（第二十八批「搜索中添加的音乐无法播放」）：在线却解析
        // 不出直链（VIP/版权/接口抖动）时绝不把空源塞进内核 —— 空源会
        // 被内核当 asset 解析报错，到达该曲时整条播放链卡死。只有离线
        // 降级态才允许未解析曲目入队（播放时再解析，联网自动接续）。
        if (_offlineFullQueue == null) {
          return '该歌曲暂时无法播放（VIP/版权受限或网络异常）';
        }
        target = track;
      } else {
        target = resolved.first;
      }
      // 离线降级态：内核只保留可播音源，未解析曲目不允许插进内核
      //（空源会被内核当 asset 解析报错），仅提示待联网
      if (_offlineFullQueue != null && target.needsUrlResolve) {
        return '该歌曲离线且未缓存，联网后可播';
      }
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
      // 离线降级态：插队同步写入记忆中的完整队列，联网还原后不丢歌
      final List<Track>? full = _offlineFullQueue;
      if (full != null) {
        final List<Track> full2 = List<Track>.of(full);
        final int curAt =
            full2.indexWhere((Track t) => t.id == state.currentTrack?.id);
        full2.insert((curAt + 1).clamp(0, full2.length), target);
        _offlineFullQueue = full2;
      }
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
    final String level = ref.read(audioQualityProvider).apiValue;

    final Map<int, Track> resolvedById = <int, Track>{};
    final Map<int, Track> pending = <int, Track>{};

    for (final Track t in tracks) {
      final int? nid = t.neteaseId;
      if (nid == null || nid <= 0) continue; // 非网易云（自定义直链）：直接可用
      // 本地文件源直接放行（缓存音乐列表页点播：路径已验证存在，
      // 不再走网络解析 —— 离线可用且不受当前音质档位影响）
      if (t.source.isNotEmpty && !t.source.startsWith('http')) {
        // 从缓存文件名 `songId_level.done` 提取真实档位回填音质展示
        //（与实际播放音频一致；解析不出不影响播放）
        final String base = t.source.split(Platform.pathSeparator).last;
        final RegExpMatch? m =
            RegExp(r'^\d+_([A-Za-z0-9]+)\.done$').firstMatch(base);
        if (m != null) _markCacheLevelMeta(nid, m.group(1)!);
        resolvedById[nid] = t;
        continue;
      }
      final SongUrlInfo? cached = _cachedUrl(nid);
      if (cached != null) {
        if (cached.playable) {
          resolvedById[nid] = await _withCacheSource(t, cached);
          continue;
        }
        // 需求第二十一批：不可播（VIP 灰曲）不再直接剔除 —— 先查磁盘
        // 缓存，有缓存仍可离线播（修复「有些有缓存的歌曲却无法正常播放」）
        final hit = await _cachedSourceAnyLevel(nid);
        if (hit != null && hit.path.isNotEmpty) {
          _markCacheLevelMeta(nid, hit.level); // 真实档位回填
          resolvedById[nid] = t.copyWith(source: hit.path);
        }
        continue;
      }
      // 需求第二十一批：磁盘缓存查找不再受「边听边缓存」开关限制
      //（已缓存文件始终可播，关开关只影响新增缓存）；当前档位未命中
      // 时跨档位兜底（换过音质/请求档回落的历史缓存也能命中）
      final hit = await _cachedSourceAnyLevel(nid);
      if (hit != null && hit.path.isNotEmpty) {
        _markCacheLevelMeta(nid, hit.level); // 真实档位回填
        resolvedById[nid] = t.copyWith(source: hit.path);
        continue;
      }
      pending[nid] = t;
    }

    if (pending.isNotEmpty) {
      try {
        final NeteaseRepository repo = ref.read(neteaseRepositoryProvider);
        final List<SongUrlInfo> urls =
            await repo.songUrls(pending.keys.toList(), level: level);
        // 同步真实音质元数据（需求：音质项展示真实频率/真实品质）
        ref.read(songMetaProvider.notifier).upsertAll(<int, SongUrlInfo>{
          for (final SongUrlInfo u in urls) u.id: u,
        });
        for (final SongUrlInfo u in urls) {
          final Track? t = pending[u.id];
          if (t == null) continue;
          _storeUrl(u.id, u);
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

  /// 磁盘缓存查找（档位感知）：当前音质档位优先，未命中跨档位择优 ——
  /// 先「高于请求档、距离最近」（本地高档不耗流量只会更好），再
  /// 「低于请求档、距离最近」（离线可播优先于档位一致）。
  /// 需求第二十一批：修复「有些有缓存的歌曲却无法正常播放」；
  /// 需求第二十三批：修复隐藏恶性 bug —— 旧版跨档位按最近使用任取，
  /// 历史低档缓存（如 64k/标准 MP3）会顶着高音质设置被静默播放且
  /// 音质展示仍报 URL 响应的高档位。
  Future<({String path, String level})?> _cachedSourceAnyLevel(int nid) async {
    try {
      final SongCacheService cache = ref.read(songCacheProvider);
      final String level = ref.read(audioQualityProvider).apiValue;
      final String? exact = await cache.cachedPathFor(nid, level);
      if (exact != null && exact.isNotEmpty) return (path: exact, level: level);
      return await cache.cachedFileBestFor(nid, level);
    } catch (_) {
      return null;
    }
  }

  /// 播放本地缓存文件时，以文件名中的真实档位回填音质元数据 ——
  /// 音质展示必须与实际播放的音频一致（sr/br 本地不可知，不虚构，
  /// 展示层自动只显档位名）。level 为空时不写。
  void _markCacheLevelMeta(int nid, String level) {
    if (level.isEmpty) return;
    ref.read(songMetaProvider.notifier).upsertAll(<int, SongUrlInfo>{
      nid: SongUrlInfo(id: nid, url: '', level: level),
    });
  }

  /// 缓存感知的播放源选择：
  ///  - 磁盘命中（当前档位优先，跨档位择优）→ 本地文件（秒开省流量）；
  ///  - 未命中：网络 URL（落盘延后到开播时，见 _cacheCurrentTrack）。
  /// 需求第二十一批：不再受「边听边缓存」开关限制 —— 已缓存文件
  /// 始终优先本地播放（关开关只影响新增缓存，不废弃已有缓存）。
  Future<Track> _withCacheSource(Track t, SongUrlInfo u) async {
    final int id = t.neteaseId!;
    try {
      final hit = await _cachedSourceAnyLevel(id);
      if (hit != null && hit.path.isNotEmpty) {
        _markCacheLevelMeta(id, hit.level); // 真实档位回填（恶性 bug 修复）
        return t.copyWith(source: hit.path);
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
      SongUrlInfo? info = _cachedUrl(id);
      info ??= await _resolveSingleUrl(id);
      if (info == null || !info.playable) return;
      if (ref.read(listenCacheProvider)) {
        final String? cached = await cache.cachedPathFor(id, level);
        if (cached != null) return; // 已缓存，无需预载
        final bool ok = await cache.download(id, level, info.url);
        if (ok) {
          // 预载落盘同样写入展示元信息（否则缓存页该条无歌名/歌手/封面）
          _saveCacheMeta(next, level);
          refreshCacheProviders(ref);
        }
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
      ref.read(songMetaProvider.notifier).upsertAll(<int, SongUrlInfo>{
        for (final SongUrlInfo u in urls) u.id: u,
      });
      for (final SongUrlInfo u in urls) {
        _storeUrl(u.id, u);
        if (u.playable) return u;
      }
    } catch (_) {}
    return null;
  }

  /// 收藏列表/恢复场景：队列里存在未解析直链的曲目时，整体重新解析。
  ///
  /// 第二十一批修复（无网播放彻底修复）：
  ///  - 合并不再有破坏性：解析失败的曲目保留原位（旧实现把队列整体
  ///    替换为已解析子集，无网播放一次后队列被永久裁短，联网也回不来）；
  ///  - 仅当全部曲目直链就绪才重装内核（含未解析曲目的队列不能直接
  ///    装载，空源会被内核当 asset 报错；部分就绪场景由
  ///    [_degradeToPlayableSubset] 降级装载可播子集）。
  Future<void> requeueIfNeeded() async {
    final bool needsResolve = state.queue.any((Track t) => t.needsUrlResolve);
    if (!needsResolve) return;
    final List<Track> resolved = await resolveTracks(state.queue);
    if (resolved.isEmpty) {
      // 需求：离线失败联网后自动接续 —— 置位由网络恢复事件消费
      _networkResumePending = true;
      state = state.copyWith(error: '播放链接已失效，且重新获取失败');
      return;
    }
    final Map<int, Track> byId = <int, Track>{
      for (final Track t in resolved)
        if (t.neteaseId != null) t.neteaseId!: t,
    };
    // 非破坏性合并：解析失败的曲目保留原位，联网恢复后整体重试
    final List<Track> merged = <Track>[
      for (final Track t in state.queue) byId[t.neteaseId] ?? t,
    ];
    final Track? cur = state.currentTrack;
    int startIdx = state.index.clamp(0, merged.length - 1);
    if (cur != null) {
      final int found = merged.indexWhere((Track t) => t.id == cur.id);
      if (found >= 0) startIdx = found;
    }
    state = state.copyWith(queue: merged, index: startIdx);
    if (merged.any((Track t) => t.needsUrlResolve)) {
      // 仍有未解析曲目（离线部分命中）：不重装内核，标记待网络恢复接续；
      // 内核为空时由调用方（playPause / _onNetworkRestored）降级装载子集
      _networkResumePending = true;
      return;
    }
    await _handler.loadQueue(merged, initialIndex: startIdx);
  }

  /// 离线降级装载（需求第二十一批：彻底修复无网播放）：
  /// 队列中仅部分曲目直链/缓存就绪时，内核只装载可播子集（保持相对
  /// 顺序），state.queue 同步收缩为子集以保持 index 对齐；完整队列
  /// 存入 [_offlineFullQueue]，网络恢复后由 [_onNetworkRestored] 还原
  /// 并整体重解析。返回是否执行了降级装载。
  Future<bool> _degradeToPlayableSubset() async {
    if (_offlineFullQueue != null) return false; // 已处于降级态
    final List<Track> full = state.queue;
    final List<Track> playable = <Track>[
      for (final Track t in full)
        if (!t.needsUrlResolve) t,
    ];
    if (playable.isEmpty || playable.length == full.length) return false;
    final Track? current = state.currentTrack;
    int idx = current == null
        ? 0
        : playable.indexWhere((Track t) => t.id == current.id);
    if (idx < 0) {
      // 当前曲目不可播：取原队列中当前曲目之后的首个可播曲目
      final int start = state.index.clamp(0, full.length - 1);
      for (int i = start; i < full.length && idx < 0; i++) {
        idx = playable.indexWhere((Track t) => t.id == full[i].id);
      }
      if (idx < 0) idx = 0;
    }
    _offlineFullQueue = full;
    state = state.copyWith(queue: playable, index: idx);
    await _handler.loadQueue(playable, initialIndex: idx);
    return true;
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
      // 第十七批兜底：内核仍为空（恢复流程未装载/装载被跳过）时
      // 强制装载一次 —— 否则 play() 无源可放，点击播放毫无反应。
      // 未解析曲目先整体刷新直链（空源会被内核当 asset 解析报错）
      if (_handler.player.audioSources.isEmpty && state.queue.isNotEmpty) {
        try {
          if (state.queue.any((Track t) => t.needsUrlResolve)) {
            await requeueIfNeeded();
          }
          if (_handler.player.audioSources.isEmpty) {
            if (!state.queue.any((Track t) => t.needsUrlResolve)) {
              await _handler.loadQueue(
                state.queue,
                initialIndex: state.index.clamp(0, state.queue.length - 1),
              );
            } else {
              // 需求第二十一批：无网部分命中 —— 仅装载可播子集继续播放，
              // 完整队列记忆下来，联网恢复后整体还原重解析
              await _degradeToPlayableSubset();
            }
          }
        } catch (e) {
          debugPrint('playPause: 内核兜底装载失败：$e');
        }
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
        // 需求：联网后自动接续 —— 由网络恢复事件刷新直链并恢复播放
        _networkResumePending = true;
        state = state.copyWith(error: '该歌曲暂无法播放（离线且未缓存，联网后自动重试）');
        return;
      }
    }
    // 内核空兜底（无网启动从未装载成功、联网后直接点歌/切歌）：
    // 先就绪直链并装载内核，否则空队列 seek(index:) 直接抛错
    if (_handler.player.audioSources.isEmpty) {
      try {
        if (state.queue.any((Track t) => t.needsUrlResolve)) {
          await requeueIfNeeded();
          if (state.queue.any((Track t) => t.needsUrlResolve)) {
            // 需求第二十一批：离线部分命中 —— 降级装载可播子集继续点播
            //（完整队列已记忆，联网恢复后还原），不再直接放弃
            final bool degraded = await _degradeToPlayableSubset();
            if (!degraded) {
              _networkResumePending = true;
              return; // 全队列都解析不齐（离线且无缓存）：等网络恢复接续
            }
          }
        } else {
          await _handler.loadQueue(
            state.queue,
            initialIndex: state.index.clamp(0, state.queue.length - 1),
          );
        }
      } catch (e) {
        debugPrint('_jumpTo: 内核兜底装载失败：$e');
      }
    }
    // 解析/装载/降级可能收缩队列致下标漂移：按曲目 id 重新定位
    //（_degradeToPlayableSubset 后队列仅含可播子集，safe 可能越界）
    final List<Track> q = state.queue;
    if (q.isEmpty) return;
    final Track target =
        safe < q.length ? q[safe] : q[state.index.clamp(0, q.length - 1)];
    final int relocated = q.indexWhere((Track t) => t.id == target.id);
    final int safe2 = relocated >= 0 ? relocated : safe.clamp(0, q.length - 1);
    state = state.copyWith(index: safe2);
    await _handler.player.seek(Duration.zero, index: safe2);
    if (!state.playing) {
      await _handler.play();
    }
    _schedulePlayStat(state.queue[safe2]);
    _schedulePersist();
    _schedulePreload();
  }

  Future<void> seek(Duration position) => _handler.seek(position);

  /// 音源加载失败自动恢复（第二十八批「有时播完歌曲后无法正常播放
  /// 下一首」「搜索中添加的音乐无法播放」根治）：
  ///  - 直链约 20 分钟过期：队列长时间播放后，内核自动前进到早已
  ///    解析的曲目时报错停摆（旧版无任何恢复，听众视角即卡死）；
  ///  - 离线降级/历史版本插入的未解析曲目到达播放点：空源报错。
  /// 恢复策略：强制绕过直链缓存重新解析当前曲目 → 原位续播（保留
  /// 进度）；解析不出（VIP/下架/断网）→ 跳下一首（handler 侧连续
  /// 失败熔断防全队列灰曲时无限快进）。
  Future<void> _recoverCurrentSource() async {
    if (!state.loaded || state.queue.isEmpty) return;
    final int idx = state.index.clamp(0, state.queue.length - 1);
    final Track t = state.queue[idx];
    final int? nid = t.neteaseId;
    if (nid == null || nid <= 0) {
      // 本地/空源曲目无法重解析：跳下一首
      await next();
      return;
    }
    try {
      // 强制绕过内存缓存（旧直链可能已过期，15 分钟 TTL 之外本就失效）
      _urlCache.remove(nid);
      _urlCacheAt.remove(nid);
      final SongUrlInfo? u = await _resolveSingleUrl(nid);
      if (u == null || !u.playable) {
        await next(); // VIP/下架：跳下一首
        return;
      }
      final Track nt = await _withCacheSource(t, u);
      final List<Track> q = List<Track>.of(state.queue);
      q[idx] = nt;
      state = state.copyWith(queue: q);
      final Duration pos = _handler.player.position;
      await _handler.loadQueue(q, initialIndex: idx);
      if (pos > Duration.zero) {
        await _handler.seek(pos);
      }
      await _handler.play();
      _schedulePreload();
    } catch (e) {
      debugPrint('_recoverCurrentSource: 重解析失败，跳下一首：$e');
      await next();
    }
  }

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
    // 循环语义交内核：one = 单曲循环；all = 列表循环（队列播完自动回头）；
    // off = 播完停止。⚠️ 修复（第二十八批「有时播完歌曲后无法正常播放
    // 下一首」）：旧版把 all 映射成 LoopMode.off —— 列表循环模式队列
    // 播完就停，永远循环不起来。
    await _handler.player.setLoopMode(switch (nextMode) {
      RepeatMode.one => LoopMode.one,
      RepeatMode.all => LoopMode.all,
      RepeatMode.off => LoopMode.off,
    });
  }

  Future<void> setSpeed(double speed) async {
    state = state.copyWith(speed: speed);
    await _handler.setSpeed(speed);
  }

  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }
}
