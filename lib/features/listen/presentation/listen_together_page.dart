/// 一起听（实验性 Beta）：局域网播放同步。
///
///  - 发起一起听：本机开房间（内置 HttpServer），展示本机 IP + 端口，
///    支持一键分享邀请文案；房主播放状态实时供给；
///  - 加入一起听：输入房主 IP:端口 → 校验房间 → 轮询跟随
///    （歌曲切换 / 进度偏差 > 3.5s / 播放暂停同步）；
///  - 需求：标明「实验性 Beta」；接入两台设备需在同一 Wi-Fi。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/platform_actions.dart';
import '../../../core/widgets/cover_image.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';
import '../services/listen_together_service.dart';

/// 全局唯一同步服务实例
final Provider<ListenTogetherService> listenServiceProvider =
    Provider<ListenTogetherService>((Ref ref) => ListenTogetherService());

class ListenTogetherPage extends ConsumerStatefulWidget {
  const ListenTogetherPage({super.key});

  @override
  ConsumerState<ListenTogetherPage> createState() => _ListenTogetherPageState();
}

class _ListenTogetherPageState extends ConsumerState<ListenTogetherPage> {
  bool _hosting = false;
  bool _joined = false;
  int _port = 0;
  List<String> _ips = const <String>[];
  int _listeners = 0;
  ListenState? _remote;
  bool _busy = false;
  bool _switchingSong = false;
  final TextEditingController _hostCtrl = TextEditingController();

  ListenTogetherService get _svc => ref.read(listenServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _svc.onRemoteState = _onRemoteState;
      await _refreshIps();
    });
  }

  @override
  void dispose() {
    // 离开页面：关房间 / 停止跟随
    if (_hosting) _svc.stop();
    if (_joined) _svc.stop();
    super.dispose();
  }

  Future<void> _refreshIps() async {
    final List<String> ips = await ListenTogetherService.localIps();
    if (!mounted) return;
    setState(() => _ips = ips);
  }

  // ---------------------------------------------------------------- 主机

  Future<void> _startHosting() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final int port = await _svc.startHosting(() {
        final PlayerState ps = ref.read(playerProvider);
        final Track? t = ps.currentTrack;
        return ListenState(
          songId: t?.neteaseId ?? 0,
          title: t?.title ?? '',
          artist: t?.artist ?? '',
          cover: t?.cover ?? '',
          positionMs:
              ref.read(audioHandlerProvider).player.position.inMilliseconds,
          isPlaying: ps.playing,
        );
      });
      if (!mounted) return;
      setState(() {
        _hosting = true;
        _port = port;
        _joined = false;
      });
      _startListenerTicker();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('开启失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startListenerTicker() {
    Future<void>.delayed(const Duration(seconds: 2), () async {
      if (!mounted || !_hosting) return;
      // 轻量刷新听众数（通过自查询 ping 精度有限，改为服务内计数展示）
      setState(() => _listeners = _svc.listeners.length);
      _startListenerTicker();
    });
  }

  Future<void> _stopHosting() async {
    await _svc.stop();
    if (!mounted) return;
    setState(() {
      _hosting = false;
      _listeners = 0;
    });
  }

  Future<void> _shareInvite() async {
    final String ip = _ips.isNotEmpty ? _ips.first : '';
    await PlatformActions.shareText(
      '【MingMusic 一起听】在「我的 → 播放页设置 → 一起听」选择「加入一起听」，'
      '输入地址 $ip:$_port 即可同步收听（需同一 Wi-Fi）。',
    );
  }

  // ---------------------------------------------------------------- 客人

  Future<void> _join() async {
    if (_busy) return;
    final String raw = _hostCtrl.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入房主地址（IP:端口）')));
      return;
    }
    final List<String> parts = raw.split(':');
    final String host = parts.first;
    final int port = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    if (port <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('地址格式应为 IP:端口')));
      return;
    }
    setState(() => _busy = true);
    try {
      _svc.onRemoteState = _onRemoteState;
      await _svc.join(host, port);
      if (!mounted) return;
      setState(() {
        _joined = true;
        _hosting = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已加入一起听，正在同步播放')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    await _svc.stop();
    if (!mounted) return;
    setState(() {
      _joined = false;
      _remote = null;
    });
  }

  /// 跟随远端状态（需求：歌曲/进度/播放暂停同步）
  Future<void> _onRemoteState(ListenState s) async {
    if (!mounted || !_joined) return;
    _remote = s;
    if (mounted) setState(() {});

    final PlayerNotifier notifier = ref.read(playerProvider.notifier);
    final PlayerState ps = ref.read(playerProvider);
    final Track? current = ps.currentTrack;

    // ① 歌曲变化 → 播放远端歌曲（neteaseId 自动解析直链）
    final int remoteId = s.songId;
    if (remoteId > 0 && current?.neteaseId != remoteId && !_switchingSong) {
      _switchingSong = true;
      try {
        final Track track = Track(
          id: 'listen-$remoteId',
          title: s.title.isEmpty ? '一起听·同步歌曲' : s.title,
          artist: s.artist,
          album: '一起听',
          source: '',
          cover: s.cover.isEmpty ? null : s.cover,
          isNetwork: true,
          neteaseId: remoteId,
        );
        await notifier.playSongs(<Track>[track], queueTitle: '一起听');
      } catch (_) {
      } finally {
        _switchingSong = false;
      }
      return; // 切歌后等下一轮再校进度
    }

    // ② 播放状态同步
    if (s.isPlaying != ps.playing) {
      await notifier.playPause();
      return;
    }

    // ③ 进度偏差 > 3.5s → seek
    if (s.isPlaying) {
      final Duration mine = ref.read(audioHandlerProvider).player.position;
      final int drift = mine.inMilliseconds - s.positionMs;
      if (drift.abs() > 3500) {
        await ref
            .read(audioHandlerProvider)
            .player
            .seek(Duration(milliseconds: s.positionMs));
      }
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlayerState ps = ref.watch(playerProvider);
    final Track? track = ps.currentTrack;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          children: <Widget>[
            const Text('一起听',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.16),
                border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.55), width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('实验性 Beta',
                  style: TextStyle(
                      color: Colors.amber,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          // Beta 说明卡
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: Colors.amber.withValues(alpha: 0.3), width: 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.science_rounded,
                    size: 18, color: Colors.amber.withValues(alpha: 0.9)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '实验性功能：与好友在同一 Wi-Fi 下同步收听。'
                    '由发起方播放，加入方自动跟随歌曲与进度；'
                    'VIP 歌曲需各自具备播放权限。',
                    style: TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (!_hosting && !_joined) ...<Widget>[
            _RoleCard(
              icon: Icons.podcasts_rounded,
              title: '发起一起听',
              subtitle: '本机创建房间，好友加入后同步收听你的播放',
              busy: _busy,
              onTap: _startHosting,
            ),
            const SizedBox(height: 12),
            _JoinCard(
              controller: _hostCtrl,
              busy: _busy,
              onJoin: _join,
            ),
          ],

          if (_hosting) ...<Widget>[
            _RoomCard(
              title: '房间已开启',
              actionLabel: '分享邀请',
              onAction: _shareInvite,
              onClose: _stopHosting,
              closeLabel: '关闭房间',
              children: <Widget>[
                for (final String ip in _ips)
                  _KV('地址', '$ip:$_port', copyable: true),
                _KV(
                    '正在播放',
                    track == null
                        ? '未在播放（请先播放一首歌曲）'
                        : '${track.title} - ${track.artist}'),
                _KV('听众', _listeners <= 0 ? '暂无听众（等待好友加入）' : '$_listeners 位听众'),
              ],
            ),
          ],

          if (_joined) ...<Widget>[
            _RoomCard(
              title: '已加入一起听',
              actionLabel: null,
              onAction: null,
              onClose: _leave,
              closeLabel: '离开',
              children: <Widget>[
                if (_remote != null) ...<Widget>[
                  _KV(
                      '正在同步',
                      _remote!.title.isEmpty
                          ? '等待房主播放'
                          : '${_remote!.title} - ${_remote!.artist}'),
                  _KV('状态', _remote!.isPlaying ? '播放中' : '已暂停'),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (_remote != null && _remote!.cover.isNotEmpty)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: CoverImage(src: _remote!.cover, size: 180, radius: 16),
                ),
              ),
          ],

          const SizedBox(height: 20),
          Center(
            child: Text(
              '当前播放：${track == null ? '未在播放' : '${track.title} - ${track.artist}'}',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 组件

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.busy,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[AppConstants.brandColor, Color(0xFFB31F1F)],
                  ),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, size: 23, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title,
                        style: const TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.chevron_right_rounded,
                    size: 22, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _JoinCard extends StatelessWidget {
  const _JoinCard({
    required this.controller,
    required this.onJoin,
    required this.busy,
  });

  final TextEditingController controller;
  final VoidCallback onJoin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('加入一起听',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('输入房主分享的地址（IP:端口）',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: controller,
                    keyboardType: TextInputType.text,
                    decoration: InputDecoration(
                      hintText: '例如 192.168.1.8:28895',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppConstants.brandColor,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12)),
                  onPressed: busy ? null : onJoin,
                  child: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('加入'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.title,
    required this.children,
    required this.actionLabel,
    required this.onAction,
    required this.closeLabel,
    required this.onClose,
  });

  final String title;
  final List<Widget> children;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String closeLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.sync_rounded,
                    size: 18, color: AppConstants.brandColor),
                const SizedBox(width: 6),
                Text(title,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                if (actionLabel != null) ...<Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppConstants.brandColor),
                      onPressed: onAction,
                      icon: const Icon(Icons.share_rounded, size: 16),
                      label: Text(actionLabel!),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: OutlinedButton(
                    onPressed: onClose,
                    child: Text(closeLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.label, this.value, {this.copyable = false});

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 68,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
          if (copyable)
            GestureDetector(
              onTap: () {
                PlatformActions.shareText(value);
              },
              child: Icon(Icons.copy_rounded,
                  size: 15,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
