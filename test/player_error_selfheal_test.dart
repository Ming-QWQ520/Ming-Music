/// 播放错误自愈链路单元测试（403 播放中停摆根治第二阶段）：
///
/// 覆盖 just_audio 0.10.x 新错误模型下的自愈契约：
///  1. 平台错误事件（PlaybackEventMessage 带 errorCode）经 errorStream
///     到达 → handler 记录 lastFatalErrorAt / lastErrorPosition；
///  2. 1.2s 延迟确认停摆（!playing || idle）后触发上层自愈回调；
///  3. clearFatalError 清除 fatal 标记。
///
/// ⚠️ 背景：第二十九批自愈挂在 playbackEventStream.onError 上，而
/// 0.10.x 中该流的 onError 处理器为空实现（错误改走 errorStream 的
/// PlayerException），自愈从未触发 —— 403 后用户须手动暂停/播放两次。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:ming_music/features/player/services/ming_audio_handler.dart';

class _MockJustAudioPlatform extends JustAudioPlatform {
  _MockPlayerPlatform? playerPlatform;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    playerPlatform ??= _MockPlayerPlatform('mock_${request.id}');
    return playerPlatform!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
          DisposePlayerRequest request) async =>
      DisposePlayerResponse();
}

class _MockPlayerPlatform extends AudioPlayerPlatform {
  _MockPlayerPlatform(super.id);

  final StreamController<PlaybackEventMessage> events =
      StreamController<PlaybackEventMessage>.broadcast();

  /// 推送一个平台事件（等价原生 onPlaybackEvent）
  void emit(PlaybackEventMessage message) => events.add(message);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async =>
      LoadResponse(duration: null);

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async =>
      DisposeResponse();

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
          ConcatenatingInsertAllRequest request) async =>
      ConcatenatingInsertAllResponse();

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
          ConcatenatingRemoveRangeRequest request) async =>
      ConcatenatingRemoveRangeResponse();

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
          ConcatenatingMoveRequest request) async =>
      ConcatenatingMoveResponse();

  // 以下为 just_audio 0.10.x 激活/装载链路会触发的其余平台方法，
  // 统一空实现（测试只关心事件流，不关心这些副作用）
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(
          SetAllowsExternalPlaybackRequest request) async =>
      SetAllowsExternalPlaybackResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(
          AudioEffectSetEnabledRequest request) async =>
      AudioEffectSetEnabledResponse();
}

PlaybackEventMessage _idleErrorEvent({
  int errorCode = 2303, // ExoPlayer ERROR_CODE_IO_BAD_HTTP_STATUS（HTTP 403 等）
  String errorMessage = 'Response code: 403',
  Duration position = const Duration(minutes: 9),
}) =>
    PlaybackEventMessage(
      processingState: ProcessingStateMessage.idle,
      updateTime: DateTime.now(),
      updatePosition: position,
      bufferedPosition: position,
      duration: const Duration(minutes: 10),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );

void main() {
  // just_audio 平台通道在纯 Dart 测试环境不可用：注入 mock 平台。
  // AudioPlayer 构造还会注册 audio_session 的 method call handler，
  // 需先初始化 Flutter binding。
  TestWidgetsFlutterBinding.ensureInitialized();
  final _MockJustAudioPlatform platform = _MockJustAudioPlatform();
  setUpAll(() {
    JustAudioPlatform.instance = platform;
  });

  /// 激活内核：空队列 play() 不会调用 platform.init（不会订阅平台
  /// 事件流）—— 先装载一个音源并在 load 等待 currentIndex 广播时
  /// 补发 ready 事件，再 play 置 playing=true，完整模拟「播放中」。
  Future<MingAudioHandler> activateHandler() async {
    final MingAudioHandler handler = MingAudioHandler();
    // setAudioSources(preload) → load() → _setPlatformActive(true) →
    // platform.init（异步），稍等后 mock 平台才就绪
    final Future<Duration?> loading =
        handler.player.setAudioSources(<ja.AudioSource>[
      ja.AudioSource.uri(Uri.parse('https://mock.local/a.mp3')),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final _MockPlayerPlatform? mp = platform.playerPlatform;
    if (mp == null) {
      try {
        await loading;
      } catch (_) {}
    }
    final _MockPlayerPlatform mock = mp ?? platform.playerPlatform!;
    mock.emit(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(minutes: 10),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    try {
      await loading;
    } catch (e) {
      // ignore: avoid_print
      print('DEBUG load error: $e');
    }
    try {
      await handler.player.play();
    } catch (e) {
      // ignore: avoid_print
      print('DEBUG play error: $e');
    }
    return handler;
  }

  group('MingAudioHandler 错误自愈链路（403 根治第二阶段）', () {
    test('初始无 fatal 标记；clearFatalError 幂等', () {
      final MingAudioHandler handler = MingAudioHandler();
      expect(handler.lastFatalErrorAt, isNull);
      handler.clearFatalError();
      expect(handler.lastFatalErrorAt, isNull);
      expect(handler.lastErrorPosition, Duration.zero);
    });

    test('errorStream 错误事件 → 记录 fatal 标记与进度 → 停摆确认后触发自愈回调',
        () async {
      final MingAudioHandler handler = await activateHandler();
      final _MockPlayerPlatform mock = platform.playerPlatform!;
      int recoverCalls = 0;
      handler.setPlaybackErrorHandler(() async => recoverCalls++);

      expect(handler.lastFatalErrorAt, isNull);

      // 模拟内核 fatal 错误（403，停摆于 9 分 00 秒处）
      mock.emit(_idleErrorEvent(position: const Duration(minutes: 9)));
      // 事件经 just_audio 多层管道异步传播，稍等其到达 handler
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 错误到达瞬间即记录 fatal 标记（不等延迟确认）
      expect(handler.lastFatalErrorAt, isNotNull,
          reason: '错误到达时应立即记录 fatal 标记');
      expect(handler.lastErrorPosition, const Duration(minutes: 9),
          reason: '错误到达时应立即抓取停摆前进度（供续播定位）');

      // 1.2s 延迟确认停摆（本例 idle）→ 触发自愈
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(recoverCalls, 1, reason: '停摆确认后应回调上层自愈恰好一次');
    });

    test('错误后内核自行恢复（仍在播）→ 不触发自愈回调（抖动性错误不打断播放）',
        () async {
      final MingAudioHandler handler = await activateHandler();
      final _MockPlayerPlatform mock = platform.playerPlatform!;
      int recoverCalls = 0;
      handler.setPlaybackErrorHandler(() async => recoverCalls++);

      // 模拟缓冲抖动错误：errorCode 事件但内核保持 ready（随后自行恢复）
      mock.emit(PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: const Duration(minutes: 9),
        bufferedPosition: const Duration(minutes: 9, seconds: 30),
        duration: const Duration(minutes: 10),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
        errorCode: 2004,
        errorMessage: 'timeout',
      ));
      // 1.2s 确认窗口内仍在播放（playing=true 且 ready）→ 不应自愈
      await Future<void>.delayed(const Duration(milliseconds: 1400));

      expect(recoverCalls, 0,
          reason: '抖动性错误内核自行恢复，自愈不得打断正常播放');
    });

    test('clearFatalError 清除 fatal 标记（自愈/恢复成功后调用）', () async {
      final MingAudioHandler handler = await activateHandler();
      final _MockPlayerPlatform mock = platform.playerPlatform!;
      handler.setPlaybackErrorHandler(() async {});
      mock.emit(_idleErrorEvent());
      // 事件经 just_audio 多层管道异步传播，稍等其到达 handler
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(handler.lastFatalErrorAt, isNotNull);
      handler.clearFatalError();
      expect(handler.lastFatalErrorAt, isNull);
      expect(handler.lastErrorPosition, Duration.zero);
    });
  });
}
