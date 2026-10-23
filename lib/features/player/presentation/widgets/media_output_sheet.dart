/// 媒体输出底部弹窗（需求改造）：
///  - 连接蓝牙后自动显示蓝牙设备名称（AudioManager 轮询，2.5s 刷新）；
///  - 输出设备可控：连接蓝牙时默认使用蓝牙播放；可手动勾选「本机(扬声器)」
///    强制扬声器输出，或勾选蓝牙设备切回蓝牙（ExoPlayer.setPreferredAudioDevice）；
///  - 仅保留「本机(扬声器)」与蓝牙设备 /「管理蓝牙设备」，无扫描/权限流程。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/platform_actions.dart';
import '../../providers/player_providers.dart';

/// 输出模式：auto = 跟随系统（连接蓝牙自动切蓝牙）；speaker = 强制扬声器；
/// bluetooth = 强制蓝牙（deviceId 定位具体设备）。
enum AudioOutputMode { auto, speaker, bluetooth }

/// 当前输出选择（弹窗内共享状态；每次打开默认回到 auto = 系统默认蓝牙优先）
final StateProvider<AudioOutputMode> audioOutputModeProvider =
    StateProvider<AudioOutputMode>((Ref ref) => AudioOutputMode.auto);

/// 打开媒体输出弹窗
Future<void> showMediaOutputSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) => const _MediaOutputSheet(),
  );
}

class _MediaOutputSheet extends ConsumerStatefulWidget {
  const _MediaOutputSheet();

  @override
  ConsumerState<_MediaOutputSheet> createState() => _MediaOutputSheetState();
}

class _MediaOutputSheetState extends ConsumerState<_MediaOutputSheet> {
  double _volume = 1.0;
  List<Map<String, Object?>> _devices = const <Map<String, Object?>>[];
  Timer? _poll;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _volume = ref.read(audioHandlerProvider).player.volume;
    _refreshDevices();
    // 打开期间轮询：连接蓝牙后自动显示名称，断开自动移除
    _poll = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!mounted) return;
      _refreshDevices(silent: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  List<Map<String, Object?>> get _btDevices =>
      _devices.where((Map<String, Object?> d) => d['bluetooth'] == true).toList();

  Future<void> _refreshDevices({bool silent = false}) async {
    final List<Map<String, Object?>> devices =
        await PlatformActions.localOutputDevices();
    if (!mounted) return;
    if (silent && _sameDevices(devices, _devices)) return;
    setState(() => _devices = devices);
  }

  bool _sameDevices(
      List<Map<String, Object?>> a, List<Map<String, Object?>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['id'] != b[i]['id']) return false;
    }
    return true;
  }

  /// 切换输出设备（需求：连接蓝牙默认蓝牙；可手动勾选至手机扬声器）
  Future<void> _selectOutput(AudioOutputMode mode, {int? deviceId}) async {
    if (_switching) return;
    setState(() => _switching = true);
    final bool ok = await PlatformActions.setAudioOutput(
      mode: switch (mode) {
        AudioOutputMode.auto => 'default',
        AudioOutputMode.speaker => 'speaker',
        AudioOutputMode.bluetooth => 'bluetooth',
      },
      deviceId: deviceId,
    );
    if (!mounted) return;
    setState(() => _switching = false);
    ref.read(audioOutputModeProvider.notifier).state = mode;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前设备不支持手动切换，已恢复系统自动路由')),
      );
      ref.read(audioOutputModeProvider.notifier).state = AudioOutputMode.auto;
    }
  }

  Future<void> _openBtSettings() async {
    try {
      await _mediaChannel.sendOpenBluetoothSettings();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开系统蓝牙设置')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));
    final AudioOutputMode mode = ref.watch(audioOutputModeProvider);
    final List<Map<String, Object?>> bt = _btDevices;
    final bool hasBt = bt.isNotEmpty;

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72),
      decoration: const BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('输出设备',
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              if (_switching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ),
              // ---------- 本机（扬声器） ----------
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: mode == AudioOutputMode.speaker
                        ? AppConstants.brandColor
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    playing
                        ? Icons.music_note_rounded
                        : Icons.music_off_rounded,
                    color: mode == AudioOutputMode.speaker
                        ? Colors.white
                        : theme.colorScheme.onSurface,
                    size: 22,
                  ),
                ),
                title: const Text('本机（扬声器）',
                    style:
                        TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  hasBt && mode != AudioOutputMode.speaker
                      ? '已连接蓝牙 · 点击切换至手机播放'
                      : '当前输出设备',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: mode == AudioOutputMode.speaker
                    ? Icon(Icons.check_circle_rounded,
                        color: AppConstants.brandColor, size: 22)
                    : Icon(Icons.radio_button_unchecked_rounded,
                        color: theme.colorScheme.onSurfaceVariant, size: 22),
                onTap: () => _selectOutput(AudioOutputMode.speaker),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                ),
                child: Slider(
                  value: _volume.clamp(0.0, 1.0),
                  activeColor: AppConstants.brandColor,
                  onChanged: (double v) {
                    setState(() => _volume = v);
                    ref.read(audioHandlerProvider).player.setVolume(v);
                  },
                ),
              ),
              const SizedBox(height: 6),
              // ---------- 蓝牙设备 ----------
              Text('蓝牙设备',
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              if (bt.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.bluetooth_disabled_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.6)),
                      const SizedBox(width: 8),
                      Text(
                        '未连接蓝牙音频设备',
                        style: TextStyle(
                            fontSize: 13.5,
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              else
                for (final Map<String, Object?> d in bt)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.bluetooth_audio_rounded,
                        size: 22, color: theme.colorScheme.onSurface),
                    title: Text('${d['name'] ?? '蓝牙设备'}',
                        style: const TextStyle(fontSize: 15)),
                    subtitle: Text(
                      mode == AudioOutputMode.speaker
                          ? '已连接 · 点击切回蓝牙输出'
                          : mode == AudioOutputMode.bluetooth
                              ? '正在输出'
                              : '已连接 · 默认蓝牙输出（点击锁定）',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: mode == AudioOutputMode.speaker
                        ? Icon(Icons.radio_button_unchecked_rounded,
                            color: theme.colorScheme.onSurfaceVariant, size: 22)
                        : Icon(Icons.check_circle_rounded,
                            color: AppConstants.brandColor, size: 22),
                    onTap: () => _selectOutput(
                      AudioOutputMode.bluetooth,
                      deviceId: (d['id'] as num?)?.toInt(),
                    ),
                  ),
              const Divider(height: 22, color: Colors.white10),
              // 管理蓝牙设备 → 系统蓝牙设置
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.settings_bluetooth_rounded,
                    size: 22, color: theme.colorScheme.onSurface),
                title: const Text('管理蓝牙设备', style: TextStyle(fontSize: 15)),
                subtitle: Text('前往系统设置配对/连接设备',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant)),
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                onTap: _openBtSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const MethodChannel _mediaChannel = MethodChannel('com.ming.music/media');

extension _MediaChannelX on MethodChannel {
  Future<void> sendOpenBluetoothSettings() async {
    await invokeMethod<bool>('openBluetoothSettings');
  }
}
