/// 我的页（仿网易云 UI）：
///  - 用户卡：未登录 → 登录引导卡；已登录 → 头像/昵称/VIP/等级/签名 + 听歌数据；
///  - 快捷入口：我喜欢的音乐 / 自定义直链；
///  - 我的歌单（登录后，横滑卡片，点击进歌单详情）；
///  - 设置集成：播放页自定义 / 设置 / 退出登录（仿网易云菜单列表）；
///  - 收藏与自定义直链曲目列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/data/netease_auth_repository.dart'
    show NeteaseLevel, NeteaseProfile, NeteaseUserPlaylist;
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart';
import '../../discover/presentation/playlist_detail_page.dart';
import '../../discover/presentation/widgets/song_tile.dart' show VipBadge;
import '../../player/presentation/np_settings_sheet.dart';
import '../../player/providers/player_providers.dart';
import '../../settings/presentation/settings_page.dart';
import '../domain/track.dart';
import '../providers/library_providers.dart';
import 'add_network_sheet.dart';

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
            const _QuickEntries(),
            _PlaylistRow(
              playlists: auth.loggedIn ? _playlists : null,
              onReload: _loadPlaylists,
            ),
            const _SettingsGroup(),
            const _FavoriteSection(),
            const _CustomTrackSection(),
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('登录状态校验失败',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          '网络异常或服务波动，登录信息已保留，点击重试',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.refresh_rounded,
                      size: 26,
                      color: theme.colorScheme.onSurfaceVariant),
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('未登录',
                            style: TextStyle(
                                fontSize: 16.5, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          '登录后可使用喜欢歌曲、评论点赞、我的歌单',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
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
                                    fontSize: 17, fontWeight: FontWeight.w700),
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
                                  gradient:
                                      const LinearGradient(colors: <Color>[
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
                                      color: theme.colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.4)),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Lv.${level.level}',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value:
                                        (level.progress / 100).clamp(0.0, 1.0),
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
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
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

class _QuickEntries extends ConsumerWidget {
  const _QuickEntries();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authProvider);
    final List<Track> favorites = ref.watch(favoriteTracksProvider);

    final String likeCount = auth.loggedIn
        ? (auth.likedIds.isEmpty
            ? '${favorites.length}'
            : '${auth.likedIds.length}')
        : '${favorites.length}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _EntryCard(
              icon: Icons.favorite_rounded,
              iconColor: AppConstants.brandColor,
              title: '我喜欢的音乐',
              subtitle: '$likeCount 首',
              onTap: () {
                if (favorites.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('还没有收藏的歌曲，播放页点击红心收藏')),
                  );
                  return;
                }
                ref
                    .read(playerProvider.notifier)
                    .playSongs(favorites, queueTitle: '我的收藏');
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _EntryCard(
              icon: Icons.link_rounded,
              iconColor: const Color(0xFF38BDF8),
              title: '自定义直链',
              subtitle: '添加网络音频',
              onTap: () => showAddNetworkSheet(context),
            ),
          ),
        ],
      ),
    );
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 我的歌单

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlists, required this.onReload});

  /// null = 未登录 / 加载中（隐藏区块）；空 = 已登录但无歌单
  final List<NeteaseUserPlaylist>? playlists;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return _PlaylistRowInner(playlists: playlists, onReload: onReload);
  }
}

class _PlaylistRowInner extends StatelessWidget {
  const _PlaylistRowInner({required this.playlists, required this.onReload});

  final List<NeteaseUserPlaylist>? playlists;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (playlists == null) return const SizedBox.shrink();
    if (playlists!.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                const Text('我的歌单',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                Text('${playlists!.length}',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: playlists!.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (BuildContext ctx, int i) {
                final NeteaseUserPlaylist pl = playlists![i];
                return _PlaylistCard(
                  playlist: pl,
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => PlaylistDetailPage.playlist(
                        meta: PlaylistMeta(
                          id: pl.id,
                          name: pl.name,
                          coverUrl: pl.coverUrl,
                          trackCount: pl.trackCount,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist, required this.onTap});

  final NeteaseUserPlaylist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 92,
              height: 92,
              child: CoverImage(src: playlist.coverUrl, size: 92, radius: 12),
            ),
            const SizedBox(height: 6),
            Text(
              playlist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, height: 1.3),
            ),
          ],
        ),
      ),
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
            _SettingsRow(
              icon: Icons.tune_rounded,
              label: '播放页自定义',
              subtitle: '显示模式 / 封面 / 背景 / 歌词',
              onTap: () => showNpSettingsSheet(context),
            ),
            Divider(
                height: 1,
                indent: 54,
                color: theme.dividerColor.withValues(alpha: 0.4)),
            _SettingsRow(
              icon: Icons.settings_outlined,
              label: '设置',
              subtitle: '主题 / 背景系统 / 音质 / 关于',
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                    builder: (BuildContext _) => const SettingsPage()),
              ),
            ),
            if (auth.loggedIn) ...<Widget>[
              Divider(
                  height: 1,
                  indent: 54,
                  color: theme.dividerColor.withValues(alpha: 0.4)),
              _SettingsRow(
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

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
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

// ---------------------------------------------------------------- 收藏列表

class _FavoriteSection extends ConsumerWidget {
  const _FavoriteSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> favorites = ref.watch(favoriteTracksProvider);

    return Column(
      children: <Widget>[
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              const Icon(Icons.favorite_rounded,
                  color: AppConstants.brandColor, size: 18),
              const SizedBox(width: 8),
              Text(
                '本地收藏 (${favorites.length})',
                style: const TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (favorites.isNotEmpty)
                TextButton.icon(
                  onPressed: () => ref
                      .read(playerProvider.notifier)
                      .playSongs(favorites, queueTitle: '我的收藏'),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('播放全部'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppConstants.brandColor,
                    textStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
        if (favorites.isEmpty)
          const _EmptyHint(text: '在歌曲详情或播放页点击红心，即可收藏到这里')
        else
          ...List<Widget>.generate(favorites.length, (int i) {
            final Track t = favorites[i];
            return _FavRow(
              track: t,
              current: ref.watch(playerProvider
                  .select((PlayerState s) => s.currentTrack?.id == t.id)),
              onTap: () => ref
                  .read(playerProvider.notifier)
                  .playSongs(favorites, startIndex: i),
              onMore: () => _confirmUnfavorite(context, ref, t),
            );
          }),
      ],
    );
  }

  Future<void> _confirmUnfavorite(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定不再喜欢「${track.title}」吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(favoriteTracksProvider.notifier).toggle(track);
    }
  }
}

// ---------------------------------------------------------------- 自定义直链

class _CustomTrackSection extends ConsumerWidget {
  const _CustomTrackSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> custom = ref.watch(libraryProvider);

    return Column(
      children: <Widget>[
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              const Icon(Icons.link_rounded, size: 18, color: Colors.white70),
              const SizedBox(width: 8),
              Text(
                '自定义直链 (${custom.length})',
                style: const TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => showAddNetworkSheet(context),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加'),
                style: TextButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        if (custom.isEmpty)
          const _EmptyHint(text: '支持添加任意可公开访问的音频直链')
        else
          ...List<Widget>.generate(custom.length, (int i) {
            final Track t = custom[i];
            return _FavRow(
              track: t,
              current: ref.watch(playerProvider
                  .select((PlayerState s) => s.currentTrack?.id == t.id)),
              onTap: () => ref
                  .read(playerProvider.notifier)
                  .playSongs(custom, startIndex: i),
              onMore: () =>
                  ref.read(libraryProvider.notifier).removeCustomTrack(t.id),
            );
          }),
      ],
    );
  }
}

// ---------------------------------------------------------------- 共用行

class _FavRow extends StatelessWidget {
  const _FavRow({
    required this.track,
    required this.current,
    required this.onTap,
    required this.onMore,
  });

  final Track track;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: <Widget>[
            CoverImage(src: track.cover, size: 46, radius: 8),
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
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                            color: current
                                ? AppConstants.brandColor
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (track.isVipOnly) ...<Widget>[
                        const SizedBox(width: 6),
                        const VipBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${track.artist} · ${track.album}',
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
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.more_vert_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13.5,
        ),
      ),
    );
  }
}
