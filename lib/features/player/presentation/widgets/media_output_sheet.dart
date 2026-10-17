/// 媒体输出底部弹窗（仿网易云投屏/设备连接页）：
///  - 当前播放设备「本机」+ 音量滑杆（just_audio setVolume 直连）；
///  - 「正在寻找设备...」发现态 + 官方应用权益标签 + 三步连接提示；
///  - 「连接蓝牙设备」入口：申请发现附近设备权限
///    （Android 12+ BLUETOOTH_SCAN/CONNECT，13+ NEARBY_WIFI_DEVICES，
///    旧版 ACCESS_FINE_LOCATION），被拒时展示系统设置引导。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/constants/app_constants.dart';
import '../../providers/player_providers.dart';

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
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _volume = ref.read(audioHandlerProvider).player.volume;
  }

  Future<void> _onBluetoothTap() async {
    // 「发现附近设备」权限组：按系统版本申请对应权限
    final List<Permission> permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
      Permission.location,
    ];
    final Map<Permission, PermissionStatus> statuses =
        await permissions.request();
    final bool allDenied = statuses.values
        .every((PermissionStatus s) => s.isDenied || s.isPermanentlyDenied);
    if (!mounted) return;
    setState(() => _permissionDenied = allDenied);
    if (allDenied) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('正在扫描附近设备…请确保电视/音箱与手机在同一 WLAN 下'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool playing =
        ref.watch(playerProvider.select((PlayerState s) => s.playing));

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82),
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
              const SizedBox(height: 8),
              // 官方应用权益标签
              Row(
                children: <Widget>[
                  _BenefitChip('曲库免费'),
                  const SizedBox(width: 8),
                  _BenefitChip('无损音质'),
                  const SizedBox(width: 8),
                  _BenefitChip('无缝续播'),
                ],
              ),
              const SizedBox(height: 16),
              // 搜索设备状态
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('正在寻找设备...',
                      style: TextStyle(
                          fontSize: 13.5,
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 14),
              // 三步连接提示
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _TipRow('1', '在电视应用市场搜索安装「网易云音乐」并启动'),
                    const SizedBox(height: 6),
                    _TipRow('2', '确保电视和手机在同一 WLAN 下'),
                    const SizedBox(height: 6),
                    _TipRow('3', '推荐使用车载/电视/手表/音箱版 App，无需连接手机即可享受沉浸视听'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 设备选择入口
              Text('选择设备',
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.phone_android_rounded,
                    size: 22, color: theme.colorScheme.onSurface),
                title: const Text('本机', style: TextStyle(fontSize: 15)),
                trailing: Icon(Icons.check_rounded,
                    color: AppConstants.brandColor, size: 20),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.bluetooth_audio_rounded,
                    size: 22, color: theme.colorScheme.onSurface),
                title: const Text('连接蓝牙设备',
                    style: TextStyle(fontSize: 15)),
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                onTap: _onBluetoothTap,
              ),
              if (_permissionDenied)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '附近设备权限被拒绝，无法扫描蓝牙/局域网设备；'
                    '可到系统设置中为 MingMusic 开启「附近的设备」权限。',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BenefitChip extends StatelessWidget {
  const _BenefitChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppConstants.brandColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: AppConstants.brandColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow(this.index, this.text);

  final String index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 15,
          height: 15,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.25),
          ),
          child: Text(index,
              style: const TextStyle(fontSize: 9.5, color: Colors.white)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
