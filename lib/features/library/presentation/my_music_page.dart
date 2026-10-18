/// 我的页（仿网易云 UI）：
///  - 用户卡：未登录 → 登录引导卡；已登录 → 头像/昵称/VIP/等级/签名 + 听歌数据；
///  - 快捷入口（3 宫格）：我喜欢的音乐 / 本地音乐 / 音乐云盘；
///  - 功能行：最近播放 / 听歌排行榜；
///  - 创建的歌单 + 收藏的歌单（显示歌单封面，对齐网易云列表样式）；
///  - 设置集成：播放页自定义 / 设置 / 退出登录。
library;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/netease_models.dart' show PlaylistMeta;
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/data/netease_auth_repository.dart'
    show NeteaseLevel, NeteaseProfile, NeteaseUserPlaylist;
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart';
import '../../player/presentation/np_settings_sheet.dart';

class MyMusicPage extends ConsumerStatefulWidget {
  const MyMusicPage({super.key});

  @override
  ConsumerState<MyMusicPage> createState() => _MyMusicPageState();
}

class _MyMusicPageState extends ConsumerState<MyMusicPage> {
  /// 用户歌单（登录后拉取；null = 未加载）
  List<NeteaseUserPlaylist>? _playlists;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPlaylists());
  }

  Future<void> _loadPlaylists() async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) {
      if (mounted) setState(() => _playlists = null);
      return;
    }
    try {
      final List<NeteaseUserPlaylist> list = await ref
          .read(neteaseAuthRepositoryProvider)
          .userPlaylists(auth.profile!.userId);
      if (mounted) setState(() => _playlists = list);
    } catch (_) {
      if (mounted) setState(() => _playlists = const <NeteaseUserPlaylist>[]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          '我的',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        actions: <Widget>[
          if (!auth.loggedIn)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: ActionChip(
                backgroundColor: AppConstants.brandColor,
                label: const Text('登录',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                onPressed: () => _openLogin(context),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: AppConstants.brandColor,
        onRefresh: () async {
          await ref.read(authProvider.notifier).refreshExtras();
          await _loadPlaylists();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 4, bottom: 28),
          children: <Widget>[
            _UserCard(onLogin: () => _openLogin(context)),
            _QuickEntries(loggedIn: auth.loggedIn),
            const _FeatureRows(),
            _PlaylistSections(
              playlists: auth.loggedIn ? _playlists : null,
              myUid: auth.profile?.userId ?? 0,
              onReload: _loadPlaylists,
            ),
            const _SettingsGroup(),
          ],
        ),
      ),
    );
  }

  Future<void> _openLogin(BuildContext context) async {
    await showLoginSheet(context);
    if (!mounted) return;
    // 登录成功后刷新歌单
    final AuthState auth = ref.read(authProvider);
    if (auth.loggedIn) _loadPlaylists();
  }
}

// ---------------------------------------------------------------- 用户卡

class _UserCard extends ConsumerWidget {
  const _UserCard({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authProvider);
    final ThemeData theme = Theme.of(context);

    if (auth.statusCheckFailed) {
      // 本地有登录凭证但 /login/status 校验失败（服务端抖动）：
      // 不清 cookie，展示重试卡（对齐 Zephyr 的容错策略）
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: () => ref.read(authProvider.notifier).recheckLogin(),
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 30,
                    backgroundColor:
                        theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.cloud_off_rounded,
                        size: 30, color: Colors.white38),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('登录状态校验失败',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        SizedBox(height: 4),
                        Text(
                          '网络异常或服务波动，登录信息已保留，点击重试',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.refresh_rounded,
                      size: 26, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (!auth.loggedIn) {
      // 未登录：引导卡
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Material(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onLogin,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.person_rounded,
                        size: 34, color: Colors.white38),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('未登录',
                            style: TextStyle(
                                fontSize: 16.5, fontWeight: FontWeight.w700)),
                        SizedBox(height: 4),
                        Text(
                          '登录后可使用喜欢歌曲、我的歌单、音乐云盘',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppConstants.brandColor,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    onPressed: onLogin,
                    child: const Text('立即登录',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 已登录：用户信息卡
    final NeteaseProfile? profile = auth.profile;
    final NeteaseLevel? level = auth.level;
    final String listenText = _formatListen(auth.listenSeconds);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => context.push('/listen-rank'),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _Avatar(url: profile?.avatarUrl),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  profile?.nickname ?? '网易云用户',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              // VIP：优先 /vip/info/v2（含黑胶等级），回退 profile.vipType
                              if ((auth.vip?.isVip ?? false) ||
                                  (profile?.isVip ?? false)) ...<Widget>[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                        colors: <Color>[
                                          Color(0xFFB8873B),
                                          Color(0xFFE8B45C),
                                        ]),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    (auth.vip?.redVipLevel ?? 0) > 0
                                        ? 'VIP·${auth.vip!.redVipLevel}'
                                        : 'VIP',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (level != null) ...<Widget>[
                            const SizedBox(height: 5),
                            Row(
                              children: <Widget>[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: theme
                                            .colorScheme.onSurfaceVariant
                                            .withValues(alpha: 0.4)),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Lv.${level.level}',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: (level.progress / 100)
                                          .clamp(0.0, 1.0),
                                      minHeight: 4,
                                      backgroundColor: theme
                                          .colorScheme.surfaceContainerHighest,
                                      color: AppConstants.brandColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text('${level.progress}%',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: theme
                                            .colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if ((profile?.signature ?? '').isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    profile!.signature,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (listenText.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Icon(Icons.headphones_rounded,
                          size: 14, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 5),
                      Text('累计听歌 $listenText',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatListen(int seconds) {
    if (seconds <= 0) return '';
    final int h = seconds ~/ 3600;
    final int m = (seconds % 3600) ~/ 60;
    if (h > 0) return '$h小时$m分钟';
    return '$m分钟';
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return CircleAvatar(
        radius: 30,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child:
            const Icon(Icons.person_rounded, size: 34, color: Colors.white38),
      );
    }
    return ClipOval(
      child: CoverImage(src: url, size: 60, radius: 30),
    );
  }
}

// ---------------------------------------------------------------- 快捷入口

/// 三宫格（对齐网易云「我的」页快捷入口）：喜欢的音乐 / 本地音乐 / 音乐云盘
class _QuickEntries extends ConsumerWidget {
  const _QuickEntries({required this.loggedIn});

  final bool loggedIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authProvider);
    final String likeCount =
        auth.loggedIn ? '${auth.likedIds.length}' : '—';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _EntryCard(
              icon: Icons.favorite_rounded,
              iconColor: AppConstants.brandColor,
              title: '我喜欢的音乐',
              subtitle: loggedIn ? '$likeCount 首' : '登录后可用',
              onTap: () => context.push('/liked-songs'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _EntryCard(
              icon: Icons.library_music_rounded,
              iconColor: const Color(0xFF38BDF8),
              title: '本地音乐',
              subtitle: '扫描设备音频',
              onTap: () => context.push('/local-music'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _EntryCard(
              icon: Icons.cloud_rounded,
              iconColor: const Color(0xFF4ADE80),
              title: '音乐云盘',
              subtitle: '登录后可用',
              onTap: () => context.push('/cloud-drive'),
            ),
          ),
        ],
      ),
    ).animate(delay: 40.ms).fadeIn(duration: 260.ms).slideY(begin: 0.06, end: 0);
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 21, color: iconColor),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 功能行

class _FeatureRows extends StatelessWidget {
  const _FeatureRows();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Material(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: <Widget>[
            _MenuRow(
              icon: Icons.history_rounded,
              label: '最近播放',
              onTap: () => context.push('/recent-songs'),
            ),
            Divider(
                height: 1,
                indent: 54,
                color: theme.dividerColor.withValues(alpha: 0.4)),
            _MenuRow(
              icon: Icons.leaderboard_rounded,
              label: '听歌排行',
              onTap: () => context.push('/listen-rank'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 歌单

class _PlaylistSections extends StatelessWidget {
  const _PlaylistSections({
    required this.playlists,
    required this.myUid,
    required this.onReload,
  });

  /// null = 未登录 / 加载中（隐藏区块）；空 = 已登录但无歌单
  final List<NeteaseUserPlaylist>? playlists;
  final int myUid;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (playlists == null) return const SizedBox.shrink();

    final List<NeteaseUserPlaylist> created = playlists!
        .where((NeteaseUserPlaylist p) => p.creatorUserId == myUid)
        .toList(growable: false);
    final List<NeteaseUserPlaylist> collected = playlists!
        .where((NeteaseUserPlaylist p) => p.creatorUserId != myUid)
        .toList(growable: false);
    if (created.isEmpty && collected.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (created.isNotEmpty)
          _PlaylistGroup(
            header: '创建的歌单',
            count: created.length,
            playlists: created,
          ),
        if (collected.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          _PlaylistGroup(
            header: '收藏的歌单',
            count: collected.length,
            playlists: collected,
          ),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '下拉可刷新歌单列表',
            style: TextStyle(
                fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _PlaylistGroup extends StatelessWidget {
  const _PlaylistGroup({
    required this.header,
    required this.count,
    required this.playlists,
  });

  final String header;
  final int count;
  final List<NeteaseUserPlaylist> playlists;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Row(
            children: <Widget>[
              Text(header,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Text('$count',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: <Widget>[
              for (int i = 0; i < playlists.length; i++)
                _PlaylistRowTile(
                  playlist: playlists[i],
                  isLast: i == playlists.length - 1,
                  isFirst: i == 0,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaylistRowTile extends StatelessWidget {
  const _PlaylistRowTile({
    required this.playlist,
    required this.isLast,
    required this.isFirst,
  });

  final NeteaseUserPlaylist playlist;
  final bool isLast;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 需求：歌单显示歌单封面（网易云样式：封面 44 + 名称 + 曲目数）
    final Widget row = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CoverImage(
          src: playlist.coverUrl,
          size: 46,
          radius: 8,
        ),
      ),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14.5),
      ),
      subtitle: Text(
        '${playlist.trackCount}首',
        style: TextStyle(
            fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right_rounded,
          size: 18, color: theme.colorScheme.onSurfaceVariant),
      onTap: () => context.push(
        '/playlist/${playlist.id}?name=${Uri.encodeComponent(playlist.name)}',
        extra: PlaylistMeta(
          id: playlist.id,
          name: playlist.name,
          coverUrl: playlist.coverUrl,
          trackCount: playlist.trackCount,
          creatorUserId: playlist.creatorUserId,
        ),
      ),
    );
    if (isLast) return row;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
            width: 0.6,
          ),
        ),
      ),
      child: row,
    );
  }
}

// ---------------------------------------------------------------- 设置组

class _SettingsGroup extends ConsumerWidget {
  const _SettingsGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authProvider);
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Material(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: <Widget>[
            _MenuRow(
              icon: Icons.tune_rounded,
              label: '播放页自定义',
              subtitle: '显示模式 / 封面 / 背景 / 歌词',
              onTap: () => showNpSettingsSheet(context),
            ),
            Divider(
                height: 1,
                indent: 54,
                color: theme.dividerColor.withValues(alpha: 0.4)),
            _MenuRow(
              icon: Icons.settings_outlined,
              label: '设置',
              subtitle: '主题 / 背景系统 / 音质 / 关于',
              onTap: () => context.push('/settings'),
            ),
            if (auth.loggedIn) ...<Widget>[
              Divider(
                  height: 1,
                  indent: 54,
                  color: theme.dividerColor.withValues(alpha: 0.4)),
              _MenuRow(
                icon: Icons.logout_rounded,
                label: '退出登录',
                subtitle: auth.profile?.nickname ?? '',
                danger: true,
                onTap: () => _confirmLogout(context, ref),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定退出当前网易云音乐账号吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(authProvider.notifier).logout();
    }
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle = '',
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color? color = danger ? AppConstants.brandColor : null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: <Widget>[
            Icon(icon,
                size: 20,
                color: color ??
                    theme.colorScheme.onSurface.withValues(alpha: 0.75)),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                          color: color)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
