/// 个人主页（对齐 Zephyr ProfileView + 其使用的全部 API）：
///
/// 数据来源（与 Zephyr 一一对应）：
///  - /login/status（authProvider.profile）       用户基本信息
///  - /user/detail?uid=                           签名/注册天数/性别/听歌首数
///  - /vip/info/v2（authProvider.vip）            VIP 状态与黑胶等级
///  - /user/level（authProvider.level）           等级/登录天数/播放次数
///  - /listen/data/total（authProvider.listenSeconds）总听歌时长
///  - /yunbei/info / /yunbei/sign                 云贝余额 / 云贝签到
///  - /daily_signin / /vip/sign                   每日签到 / VIP 乐签
///  - /vip/growthpoint                            VIP 成长值
///  - /user/playlist?uid=                         我的歌单（横向滚动）
///  - /record/recent/song?limit=10                最近播放（前 10）
///  - /user/record?uid=&type=1                    听歌排行·本周（前 10）
///  - /likelist?uid=（authProvider.likedIds）     喜欢列表
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/netease_models.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/data/netease_auth_repository.dart';
import '../../auth/providers/auth_providers.dart';
import '../../auth/presentation/login_sheet.dart';
import '../../discover/data/netease_providers.dart';
import '../../discover/data/netease_repository.dart';
import '../../library/domain/track.dart';
import '../../player/providers/player_providers.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  NeteaseUserDetail? _detail;
  NeteaseYunbeiInfo? _yunbei;
  NeteaseVipGrowth? _growth;
  List<NeteaseUserPlaylist>? _playlists;
  List<PlayRecordSong>? _recent;
  List<PlayRecordSong>? _weekRank;
  bool _signing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  Future<void> _loadAll() async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return;
    final int uid = auth.profile!.userId;
    final NeteaseAuthRepository repo = ref.read(neteaseAuthRepositoryProvider);
    final NeteaseRepository discover = ref.read(neteaseRepositoryProvider);

    // 对齐 Zephyr：并行拉取，任一失败不阻塞其余区块
    final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
      repo.userDetail(uid),
      repo.yunbeiInfo(),
      repo.vipGrowthpoint(),
      repo.userPlaylists(uid),
      discover.recentSongs(limit: 10),
      discover.userRecord(uid, week: true),
    ]);
    if (!mounted) return;
    setState(() {
      _detail = results[0] as NeteaseUserDetail?;
      _yunbei = results[1] as NeteaseYunbeiInfo?;
      _growth = results[2] as NeteaseVipGrowth?;
      _playlists = results[3] as List<NeteaseUserPlaylist>?;
      _recent = results[4] as List<PlayRecordSong>?;
      _weekRank = results[5] as List<PlayRecordSong>?;
    });
  }

  Future<void> _refresh() async {
    await ref.read(authProvider.notifier).refreshExtras();
    await _loadAll();
  }

  // ---------------------------------------------------------------- 签到

  Future<void> _signIn() async {
    if (_signing) return;
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return;
    setState(() => _signing = true);
    final NeteaseAuthRepository repo = ref.read(neteaseAuthRepositoryProvider);
    final List<String> msgs = <String>[];
    try {
      final int a = await repo.dailySignin();
      msgs.add(a == 200 ? '每日签到 +3 积分' : '今日已签到');
    } catch (_) {
      msgs.add('每日签到失败');
    }
    try {
      final int y = await repo.yunbeiSign();
      msgs.add(y == 200 ? '云贝签到成功' : '云贝今日已签');
    } catch (_) {
      // 云贝失败不提示（非关键）
    }
    try {
      final bool v = await repo.vipSign();
      if (v) msgs.add('VIP 乐签打卡成功');
    } catch (_) {
      // 非 VIP 忽略
    }
    if (!mounted) return;
    setState(() => _signing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msgs.join(' · '))),
    );
    unawaitedRefresh();
  }

  void unawaitedRefresh() {
    final NeteaseAuthRepository repo = ref.read(neteaseAuthRepositoryProvider);
    repo.yunbeiInfo().then((NeteaseYunbeiInfo info) {
      if (mounted) setState(() => _yunbei = info);
    }).catchError((Object _) {});
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authProvider);

    if (!auth.loggedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('个人主页')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Text('登录后可查看个人主页'),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppConstants.brandColor),
                onPressed: () => showLoginSheet(context),
                child: const Text('立即登录'),
              ),
            ],
          ),
        ),
      );
    }

    final NeteaseProfile profile = auth.profile!;
    final NeteaseLevel? level = auth.level;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('个人主页',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: _signing ? null : _signIn,
              icon: _signing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.edit_calendar_rounded, size: 15),
              label: const Text('签到',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppConstants.brandColor,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: <Widget>[
            _UserCard(profile: profile, detail: _detail, level: level),
            const SizedBox(height: 14),
            _ListenStatsCard(level: level),
            if (_yunbei != null || _growth != null) ...<Widget>[
              const SizedBox(height: 14),
              _SignBenefitsCard(yunbei: _yunbei, growth: _growth),
            ],
            if (_playlists != null && _playlists!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 18),
              const _SectionHeader('我的歌单'),
              _PlaylistScroller(
                  playlists: _playlists!, myUid: profile.userId),
            ],
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: _RecentColumn(items: _recent)),
                const SizedBox(width: 12),
                Expanded(child: _WeekRankColumn(items: _weekRank)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 用户卡

class _UserCard extends ConsumerWidget {
  const _UserCard({
    required this.profile,
    required this.detail,
    required this.level,
  });

  final NeteaseProfile profile;
  final NeteaseUserDetail? detail;
  final NeteaseLevel? level;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authProvider);
    final String vipText = (auth.vip?.isVip ?? false)
        ? (auth.vip!.redVipLevel > 0
            ? '黑胶 VIP·${auth.vip!.redVipLevel}'
            : '黑胶 VIP')
        : (profile.isVip ? 'VIP' : '');
    final List<String> facts = <String>[
      if ((detail?.createDays ?? 0) > 0) '已加入 ${detail!.createDays} 天',
      if ((detail?.genderLabel ?? '').isNotEmpty) detail!.genderLabel,
      if ((detail?.listenSongs ?? 0) > 0) '累计听歌 ${detail!.listenSongs} 首',
    ];

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF3A2B2B), Color(0xFF26202A)],
        ),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ClipOval(
                child: CoverImage(src: profile.avatarUrl, size: 72, radius: 36),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            profile.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (vipText.isNotEmpty) ...<Widget>[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: <Color>[
                                Color(0xFFB8873B),
                                Color(0xFFE8B45C),
                              ]),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              vipText,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (profile.signature.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 5),
                      Text(
                        profile.signature,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.62),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (facts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                for (final String f in facts)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(f,
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.72))),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 听歌统计

class _ListenStatsCard extends ConsumerWidget {
  const _ListenStatsCard({required this.level});

  final NeteaseLevel? level;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final int listenSeconds =
        ref.watch(authProvider.select((AuthState s) => s.listenSeconds));
    final String listenText = _formatListen(listenSeconds);
    // 局部提升：final 字段无法自动空提升，先落到局部变量
    final NeteaseLevel? lv = level;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.headphones_rounded,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                listenText.isEmpty ? '累计听歌时长加载中…' : '累计听歌 $listenText',
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (lv != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Text('Lv.${lv.level}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppConstants.brandColor)),
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (lv.progress / 100).clamp(0.0, 1.0),
                      minHeight: 5,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      color: AppConstants.brandColor,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('${lv.progress}%',
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ],
        ],
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

// ---------------------------------------------------------------- 签到福利

class _SignBenefitsCard extends StatelessWidget {
  const _SignBenefitsCard({required this.yunbei, required this.growth});

  final NeteaseYunbeiInfo? yunbei;
  final NeteaseVipGrowth? growth;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          _Chip(
            icon: Icons.toll_rounded,
            label: '云贝 ${yunbei?.balance ?? 0}',
            hint: (yunbei?.signed ?? false) ? '今日已签' : '签到可得云贝',
          ),
          const SizedBox(width: 10),
          if (growth != null)
            _Chip(
              icon: Icons.workspace_premium_rounded,
              label: '成长值 ${growth!.growthPoint}',
              hint: growth!.levelName.isEmpty
                  ? 'VIP Lv.${growth!.level}'
                  : growth!.levelName,
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.hint,
  });

  final IconData icon;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Expanded(
      child: Row(
        children: <Widget>[
          Icon(icon, size: 17, color: AppConstants.brandColor),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
                Text(hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 歌单横滚

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text,
          style:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    );
  }
}

class _PlaylistScroller extends ConsumerWidget {
  const _PlaylistScroller({required this.playlists, required this.myUid});

  final List<NeteaseUserPlaylist> playlists;
  final int myUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: playlists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (BuildContext context, int i) {
          final NeteaseUserPlaylist p = playlists[i];
          return GestureDetector(
            onTap: () => context.push(
              '/playlist/${p.id}?name=${Uri.encodeComponent(p.name)}',
              extra: PlaylistMeta(
                id: p.id,
                name: p.name,
                coverUrl: p.coverUrl,
                trackCount: p.trackCount,
                creatorUserId: p.creatorUserId,
              ),
            ),
            child: SizedBox(
              width: 104,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CoverImage(src: p.coverUrl, size: 104, radius: 12),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    '${p.trackCount}首',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- 两列榜单

class _RecentColumn extends ConsumerWidget {
  const _RecentColumn({required this.items});

  final List<PlayRecordSong>? items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(child: _SectionHeader('最近播放')),
            if (items != null && items!.isNotEmpty)
              GestureDetector(
                onTap: () => context.push('/recent-songs'),
                child: Text('全部',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
        if (items == null)
          const _MiniSkeleton()
        else if (items!.isEmpty)
          const _EmptyHint('暂无最近播放')
        else
          for (final PlayRecordSong r in items!) _MiniSongRow(record: r),
      ],
    );
  }
}

class _WeekRankColumn extends ConsumerWidget {
  const _WeekRankColumn({required this.items});

  final List<PlayRecordSong>? items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(child: _SectionHeader('听歌排行·本周')),
            if (items != null && items!.isNotEmpty)
              GestureDetector(
                onTap: () => context.push('/listen-rank'),
                child: Text('全部',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
          ],
        ),
        if (items == null)
          const _MiniSkeleton()
        else if (items!.isEmpty)
          const _EmptyHint('本周还没有听歌记录')
        else
          for (final PlayRecordSong r in items!) _MiniSongRow(record: r),
      ],
    );
  }
}

class _MiniSongRow extends ConsumerWidget {
  const _MiniSongRow({required this.record});

  final PlayRecordSong record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Song s = record.song;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => ref
          .read(playerProvider.notifier)
          .playSongs(<Track>[s.toTrack()], queueTitle: '单曲播放'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CoverImage(src: s.coverUrl, size: 34, radius: 6),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  Text(
                    s.artists,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (record.score > 0)
              Text('${record.score}次',
                  style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _MiniSkeleton extends StatelessWidget {
  const _MiniSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppConstants.brandColor),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
