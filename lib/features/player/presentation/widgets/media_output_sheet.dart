/// 媒体输出底部弹窗（需求改造）：
///  - 仅保留「本机」（音量直连）与蓝牙设备显示 /「管理蓝牙设备」；
///  - 连接蓝牙后自动显示蓝牙设备名称（Android AudioManager.getDevices 轮询，
///    弹窗打开期间每 2.5s 刷新，连接/断开自动切换显示）；
///  - 移除「正在寻找设备」扫描态、三步连接提示与附近设备权限申请。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../providers/player_providers.dart';

const MethodChannel _mediaChannel = MethodChannel('com.ming.music/media');

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
  List<String> _btDevices = const <String>[];
  Timer? _poll;

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

  Future<void> _refreshDevices({bool silent = false}) async {
    try {
      final Object? raw =
          await _mediaChannel.invokeMethod<Object?>('getMediaDevices');
      final List<String> names = <String>[];
      if (raw is List<Object?>) {
        for (final Object? item in raw) {
          if (item is Map<Object?, Object?>) {
            final String name = '${item['name'] ?? ''}'.trim();
            if (name.isNotEmpty) names.add(name);
          } else if (item is Map<String, Object?>) {
            final String name = '${item['name'] ?? ''}'.trim();
            if (name.isNotEmpty) names.add(name);
          }
        }
      }
      if (!mounted) return;
      if (silent &&
          names.length == _btDevices.length &&
          ListEquality().equals(names, _btDevices)) {
        return;
      }
      setState(() => _btDevices = names);
    } catch (_) {
      // 平台通道不可用（非 Android 等）：静默，保持空列表
    }
  }

  Future<void> _openBtSettings() async {
    try {
      await _mediaChannel.invokeMethod<bool>('openBluetoothSettings');
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
              Text('当前播放设备',
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              // 本机 + 音量
              Row(
                children: <Widget>[
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppConstants.brandColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      playing
                          ? Icons.music_note_rounded
                          : Icons.music_off_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('本机',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  Icon(Icons.volume_up_rounded,
                      size: 20, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
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
              const SizedBox(height: 12),
              // 蓝牙输出设备（连接后自动显示名称；多设备逐一列出）
              Text('蓝牙设备',
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              if (_btDevices.isEmpty)
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
                for (final String name in _btDevices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.bluetooth_audio_rounded,
                        size: 22,
                        color: theme.colorScheme.onSurface),
                    title: Text(name, style: const TextStyle(fontSize: 15)),
                    subtitle: Text('已连接 · 系统自动输出',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: theme.colorScheme.onSurfaceVariant)),
                    trailing: Icon(Icons.check_rounded,
                        color: AppConstants.brandColor, size: 20),
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

/// 简易列表相等判断（避免为一个小弹窗引入 collection 包）
class ListEquality {
  bool equals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
