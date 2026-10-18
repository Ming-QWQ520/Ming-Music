/// 播放页自定义底部弹出菜单（对齐网易云「播放页自定义」与 描述文件）：
///
///  1. 顶部信息区：拖拽条 + 方形专辑封面 + 歌名(VIP)/歌手 + 「为TA心动」胶囊；
///  2. 横向快捷操作（5 图标）：收藏 / 下载 / 分享 / 横屏 / 一起听；
///  3. 纵向功能列表：
///     · 信息：专辑 / 歌手(+关注) / 查看歌曲百科；
///     · 推荐：开始相似歌曲漫游 / 插播相似歌曲；
///     · 播放设置：音质 / 播放器样式 / 红心动效；
///     · 场景与模式：定时关闭 / 倍速播放 / 播放与显示设置；
///     · 更多：设为铃声 / 问题反馈；
///  4. 底部悬浮胶囊：「播放页底部功能自定义 >」（底栏按钮显隐编辑）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/platform_actions.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/providers/auth_providers.dart';
import '../../discover/data/netease_providers.dart';
import '../../library/data/download_service.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/add_to_playlist_sheet.dart';
import '../../settings/domain/settings_models.dart'
    show AudioQuality, AudioQualityX;
import '../../settings/providers/settings_providers.dart'
    show audioQualityProvider;
import '../domain/np_settings.dart';
import '../providers/np_settings_providers.dart';
import '../providers/player_providers.dart';
import 'np_settings_sheet.dart';
import 'widgets/quality_sheet.dart';

/// 弹出播放页自定义底部菜单
Future<void> showPlayerMoreSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => const _PlayerMoreSheet(),
  );
}

class _PlayerMoreSheet extends ConsumerStatefulWidget {
  const _PlayerMoreSheet();

  @override
  ConsumerState<_PlayerMoreSheet> createState() => _PlayerMoreSheetState();
}

class _PlayerMoreSheetState extends ConsumerState<_PlayerMoreSheet> {
  bool _downloading = false;
  int? _artistId;
  bool _artistLoading = false;

  /// 底部弹窗 pop 后自身 context 失效：提前持有全局 router 与 messenger
  GoRouter? _router;
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _router = GoRouter.of(context);
      _messenger = ScaffoldMessenger.of(context);
    });
  }

  Track? get _track =>
      ref.read(playerProvider.select((PlayerState s) => s.currentTrack));

  void _toast(String msg) {
    _messenger?.showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 关闭本弹窗并执行后续动作（使用提前持有的 router，避免 context 失效）
  void _popThen(void Function() action) {
    Navigator.of(context).pop();
    action();
  }

  // ------------------------------------------------------------- actions

  Future<void> _download() async {
    final Track? track = _track;
    if (track == null || _downloading) return;
    setState(() => _downloading = true);
    final DownloadResult r = await downloadTrack(ref, track);
    if (!mounted) return;
    setState(() => _downloading = false);
    _toast(r.message);
  }

  Future<void> _setRingtone() async {
    final Track? track = _track;
    if (track == null || _downloading) return;
    setState(() => _downloading = true);
    final DownloadResult r = await downloadTrack(ref, track);
    if (!mounted) return;
    setState(() => _downloading = false);
    _toast(r.ok ? '已保存到 Music/MingMusic，可在系统设置中设为铃声' : r.message);
  }

  Future<void> _resolveArtist(String name) async {
    if (_artistLoading || name.isEmpty) return;
    setState(() => _artistLoading = true);
    try {
      final int? id =
          await ref.read(neteaseRepositoryProvider).artistIdByName(name);
      if (!mounted) return;
      setState(() {
        _artistId = id;
        _artistLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _artistLoading = false);
    }
  }

  Future<void> _toggleLandscape() async {
    final bool landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    try {
      await SystemChrome.setPreferredOrientations(landscape
          ? <DeviceOrientation>[DeviceOrientation.portraitUp]
          : <DeviceOrientation>[
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
      _toast(landscape ? '已切换竖屏' : '已切换横屏');
    } catch (_) {
      _toast('切换失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Track? track = ref.watch(
        playerProvider.select((PlayerState s) => s.currentTrack));
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final AudioQuality quality = ref.watch(audioQualityProvider);
    final bool liked = (track?.neteaseId ?? 0) > 0 &&
        ref.watch(authProvider
            .select((AuthState s) => s.likedIds.contains(track!.neteaseId)));
    final Duration? sleepLeft = ref.watch(sleepTimerProvider);

    // 歌手 id 懒解析（打开面板时后台解析一次）
    if (_artistId == null &&
        !_artistLoading &&
        (track?.artist.isNotEmpty ?? false)) {
      scheduleMicrotask(() => _resolveArtist(track!.artist));
    }

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86),
      decoration: const BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 10),
            // ---------- 拖拽条 ----------
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // ---------- 顶部信息区 ----------
            if (track != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Row(
                  children: <Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CoverImage(
                          src: track.cover, size: 52, radius: 8),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (track.isVipOnly) ...<Widget>[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: AppConstants.brandColor,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: const Text(
                                    'VIP',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 「为TA心动」胶囊
                    GestureDetector(
                      onTap: () async {
                        final String? error = await ref
                            .read(authProvider.notifier)
                            .toggleLikeSong(track.neteaseId ?? 0);
                        _toast(error ?? '已更新喜欢状态');
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: liked
                                ? AppConstants.brandColor
                                : Colors.white24,
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              liked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              size: 14,
                              color: liked
                                  ? AppConstants.brandColor
                                  : Colors.white70,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '为TA心动',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: liked
                                    ? AppConstants.brandColor
                                    : Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // ---------- 横向快捷操作（5 图标） ----------
            if (track != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: <Widget>[
                    _QuickIcon(
                      icon: Icons.playlist_add_rounded,
                      label: '收藏',
                      onTap: () => showAddToPlaylistSheet(
                          context, ref, <int>[track.neteaseId ?? 0]),
                    ),
                    _QuickIcon(
                      icon: Icons.download_rounded,
                      label: '下载',
                      busy: _downloading,
                      onTap: _download,
                    ),
                    _QuickIcon(
                      icon: Icons.share_rounded,
                      label: '分享',
                      onTap: () async {
                        final int? id = track.neteaseId;
                        await PlatformActions.shareText(
                          '${track.title} - ${track.artist}'
                          '${id != null && id > 0 ? ' https://music.163.com/#/song?id=$id' : ''}',
                        );
                      },
                    ),
                    _QuickIcon(
                      icon: Icons.screen_rotation_rounded,
                      label: '横屏',
                      onTap: _toggleLandscape,
                    ),
                    _QuickIcon(
                      icon: Icons.groups_rounded,
                      label: '一起听',
                      onTap: () => _toast('一起听需要在网易云音乐 App 中发起'),
                    ),
                  ],
                ),
              ),
            const Divider(height: 18, color: Colors.white10),
            // ---------- 纵向功能列表 ----------
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                children: <Widget>[
                  const _SectionLabel('信息'),
                  if (track != null) ...<Widget>[
                    _MoreRow(
                      icon: Icons.album_outlined,
                      label: '专辑：${track.album}',
                      onTap: track.album.isNotEmpty && track.album != '单曲'
                          ? () {
                              Navigator.of(context).pop();
                              context.push(
                                  '/search?kw=${Uri.encodeComponent(track.album)}');
                            }
                          : null,
                    ),
                    _MoreRow(
                      icon: Icons.person_outline_rounded,
                      label: '歌手：${track.artist}',
                      trailing: _artistId != null
                          ? GestureDetector(
                              onTap: () async {
                                try {
                                  await ref
                                      .read(neteaseRepositoryProvider)
                                      .artistSub(_artistId!, subscribe: true);
                                  _toast('已关注歌手');
                                } catch (e) {
                                  _toast('关注失败：$e');
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: AppConstants.brandColor,
                                      width: 1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  '+ 关注',
                                  style: TextStyle(
                                      color: AppConstants.brandColor,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            )
                          : null,
                      onTap: _artistId != null
                          ? () => _popThen(() => _router?.push(
                                  '/artist/$_artistId?name=${Uri.encodeComponent(track.artist)}'))
                          : null,
                    ),
                    if ((track.neteaseId ?? 0) > 0)
                      _MoreRow(
                        icon: Icons.menu_book_rounded,
                        label: '查看歌曲百科',
                        onTap: () => _popThen(() => _router?.push(
                              '/wiki/${track.neteaseId}?title=${Uri.encodeComponent(track.title)}'
                              '&artist=${Uri.encodeComponent(track.artist)}'
                              '${track.mvId != null ? '&mv=${track.mvId}' : ''}')),
                      ),
                  ],
                  const _SectionLabel('推荐'),
                  _MoreRow(
                    icon: Icons.radar_rounded,
                    label: '开始相似歌曲漫游',
                    onTap: track?.neteaseId == null
                        ? null
                        : () async {
                            Navigator.of(context).pop();
                            final String? error = await ref
                                .read(playerProvider.notifier)
                                .startRoaming();
                            if (error != null) _toast(error);
                          },
                  ),
                  _MoreRow(
                    icon: Icons.headphones_rounded,
                    label: '插播相似歌曲',
                    onTap: track?.neteaseId == null
                        ? null
                        : () async {
                            Navigator.of(context).pop();
                            final String? error = await ref
                                .read(playerProvider.notifier)
                                .playNextSimilar();
                            if (error != null) _toast(error);
                          },
                  ),
                  const _SectionLabel('播放设置'),
                  _MoreRow(
                    icon: Icons.high_quality_rounded,
                    label: '音质：${quality.label}'
                        '${quality != AudioQuality.standard ? '' : ''}',
                    trailing: const Text(
                      'VIP',
                      style: TextStyle(
                          color: AppConstants.brandColor,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800),
                    ),
                    onTap: () => showQualitySheet(context, quality),
                  ),
                  _MoreRow(
                    icon: Icons.style_rounded,
                    label: '播放器样式',
                    trailing: Text(
                      cfg.coverStyle.label,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onTap: () => _showStylePicker(cfg),
                  ),
                  _MoreRow(
                    icon: Icons.favorite_rounded,
                    label: '红心动效',
                    trailing: Switch.adaptive(
                      value: cfg.heartEffect,
                      activeThumbColor: AppConstants.brandColor,
                      onChanged: (bool v) => ref
                          .read(npSettingsProvider.notifier)
                          .setHeartEffect(v),
                    ),
                    onTap: () => ref
                        .read(npSettingsProvider.notifier)
                        .setHeartEffect(!cfg.heartEffect),
                  ),
                  const _SectionLabel('场景与模式'),
                  _MoreRow(
                    icon: Icons.timer_outlined,
                    label: sleepLeft == null
                        ? '定时关闭'
                        : '定时关闭（剩余 ${sleepLeft.inMinutes}:${(sleepLeft.inSeconds % 60).toString().padLeft(2, '0')}）',
                    onTap: () => _showSleepTimerPicker(sleepLeft != null),
                  ),
                  _MoreRow(
                    icon: Icons.speed_rounded,
                    label: '倍速播放',
                    trailing: Text(
                      '${ref.watch(playerProvider.select((PlayerState s) => s.speed)).toStringAsFixed(1)}x',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onTap: () => _showSpeedPicker(),
                  ),
                  _MoreRow(
                    icon: Icons.display_settings_rounded,
                    label: '播放与显示设置',
                    onTap: () {
                      // 不先 pop：显示设置面板叠在当前弹窗上，避免 context 失效
                      showNpSettingsSheet(context);
                    },
                  ),
                  const _SectionLabel('更多功能'),
                  _MoreRow(
                    icon: Icons.notifications_active_outlined,
                    label: '设为铃声',
                    trailing: const Text(
                      'VIP',
                      style: TextStyle(
                          color: AppConstants.brandColor,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800),
                    ),
                    onTap: _downloading ? null : _setRingtone,
                  ),
                  _MoreRow(
                    icon: Icons.flag_outlined,
                    label: '问题反馈',
                    onTap: () async {
                      final bool ok = await PlatformActions.openUrl(
                          '${AppConstants.repoUrl}/issues');
                      if (!ok) _toast('无法打开浏览器');
                    },
                  ),
                  const SizedBox(height: 6),
                  // ---------- 底部悬浮胶囊 ----------
                  Center(
                    child: GestureDetector(
                      onTap: () => _showStripEditor(cfg),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Text(
                          '播放页底部功能自定义 >',
                          style: TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- pickers

  void _showStylePicker(NpPlayerSettings cfg) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => Container(
        decoration: const BoxDecoration(
          color: AppConstants.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 12),
              const Text('播放器样式',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final NpCoverStyle s in NpCoverStyle.values)
                ListTile(
                  title: Text(s.label, style: const TextStyle(fontSize: 15)),
                  trailing: cfg.coverStyle == s
                      ? const Icon(Icons.check_rounded,
                          color: AppConstants.brandColor, size: 20)
                      : null,
                  onTap: () {
                    ref.read(npSettingsProvider.notifier).setCoverStyle(s);
                    Navigator.of(ctx).pop();
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  void _showSleepTimerPicker(bool active) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => Container(
        decoration: const BoxDecoration(
          color: AppConstants.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 12),
              Text(active ? '定时关闭（点击取消）' : '定时关闭',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final int minutes in const <int>[15, 30, 60, 90])
                ListTile(
                  title: Text('$minutes 分钟', style: const TextStyle(fontSize: 15)),
                  onTap: () {
                    ref
                        .read(sleepTimerProvider.notifier)
                        .start(Duration(minutes: minutes));
                    Navigator.of(ctx).pop();
                    _toast('将在 $minutes 分钟后暂停播放');
                  },
                ),
              if (active)
                ListTile(
                  title: const Text('取消定时',
                      style: TextStyle(
                          fontSize: 15, color: AppConstants.brandColor)),
                  onTap: () {
                    ref.read(sleepTimerProvider.notifier).cancel();
                    Navigator.of(ctx).pop();
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedPicker() {
    final double current =
        ref.read(playerProvider.select((PlayerState s) => s.speed));
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => Container(
        decoration: const BoxDecoration(
          color: AppConstants.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 12),
              const Text('倍速播放',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final double sp in const <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                ListTile(
                  title: Text('${sp.toStringAsFixed(2)}x',
                      style: const TextStyle(fontSize: 15)),
                  trailing: current == sp
                      ? const Icon(Icons.check_rounded,
                          color: AppConstants.brandColor, size: 20)
                      : null,
                  onTap: () {
                    ref.read(playerProvider.notifier).setSpeed(sp);
                    Navigator.of(ctx).pop();
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部功能条按钮显隐编辑
  void _showStripEditor(NpPlayerSettings cfg) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) {
        final List<String> selected = List<String>.of(cfg.stripButtons);
        return StatefulBuilder(
          builder: (BuildContext ctx2, void Function(void Function()) setState2) {
            return Container(
              decoration: const BoxDecoration(
                color: AppConstants.darkSurface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const SizedBox(height: 12),
                    const Text('播放页底部功能自定义',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('按住拖动不可用，勾选决定显示与顺序（按默认顺序排列）',
                            style:
                                TextStyle(fontSize: 11.5, color: Colors.white38)),
                      ),
                    ),
                    for (final String id in kStripButtonIds)
                      CheckboxListTile(
                        value: selected.contains(id),
                        title: Text(stripButtonLabel(id),
                            style: const TextStyle(fontSize: 15)),
                        activeColor: AppConstants.brandColor,
                        onChanged: (bool? v) {
                          setState2(() {
                            if (v == true) {
                              selected.add(id);
                            } else {
                              selected.remove(id);
                            }
                          });
                        },
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppConstants.brandColor,
                          ),
                          onPressed: () {
                            ref
                                .read(npSettingsProvider.notifier)
                                .setStripButtons(selected);
                            Navigator.of(ctx2).pop();
                          },
                          child: const Text('完成'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 通用组件

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.38),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: <Widget>[
            Icon(icon,
                size: 20,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _QuickIcon extends StatelessWidget {
  const _QuickIcon({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon,
                        size: 22, color: theme.colorScheme.onSurface),
              ),
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
