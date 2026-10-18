/// 添加至歌单底部弹窗（需求）：
///  - 列出所有「我创建的歌单」（封面 + 名称 + 数量），点击即添加；
///  - 顶部「新建歌单」行：输入名称 → /playlist/create → 直接入歌；
///  - 未登录引导登录；已存在/失败给出明确提示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/data/netease_auth_repository.dart' show NeteaseUserPlaylist;
import '../../auth/presentation/login_sheet.dart';
import '../../auth/providers/auth_providers.dart';
import '../../discover/data/netease_providers.dart';


/// 打开「添加至歌单」弹窗。返回操作结果（关闭弹窗后 toast）。
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  List<int> trackIds,
) async {
  final AuthState auth = ref.read(authProvider);
  if (!auth.loggedIn) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('登录后即可添加到歌单')),
    );
    await showLoginSheet(context);
    return;
  }
  if (trackIds.isEmpty || trackIds.any((int id) => id <= 0)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('该歌曲暂不支持添加到歌单')),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => _AddToPlaylistSheet(trackIds: trackIds),
  );
}

class _AddToPlaylistSheet extends ConsumerStatefulWidget {
  const _AddToPlaylistSheet({required this.trackIds});

  final List<int> trackIds;

  @override
  ConsumerState<_AddToPlaylistSheet> createState() =>
      _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<_AddToPlaylistSheet> {
  List<NeteaseUserPlaylist>? _mine;
  String? _error;
  int? _busyId;
  bool _creating = false;

  /// 弹窗 pop 后自身 context 失效：提前持有 messenger
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _messenger = ScaffoldMessenger.of(context);
    });
    _load();
  }

  Future<void> _load() async {
    final AuthState auth = ref.read(authProvider);
    if (!auth.loggedIn) return;
    try {
      final List<NeteaseUserPlaylist> all = await ref
          .read(neteaseAuthRepositoryProvider)
          .userPlaylists(auth.profile!.userId)
          .then((List<NeteaseUserPlaylist> list) => list
              .where((NeteaseUserPlaylist p) =>
                  p.creatorUserId == auth.profile!.userId)
              .toList(growable: false));
      if (!mounted) return;
      setState(() => _mine = all);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '歌单加载失败：$e');
    }
  }

  Future<void> _addTo(int playlistId, String name) async {
    if (_busyId != null) return;
    setState(() => _busyId = playlistId);
    try {
      await ref.read(neteaseRepositoryProvider).playlistTracks(
            playlistId: playlistId,
            trackIds: widget.trackIds,
            add: true,
          );
      _messenger?.showSnackBar(
        SnackBar(content: Text('已添加到「$name」')),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _messenger?.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _createNew() async {
    if (_creating) return;
    final TextEditingController ctrl = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '请输入歌单名'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppConstants.brandColor,
            ),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _creating = true);
    try {
      final int id =
          await ref.read(neteaseRepositoryProvider).playlistCreate(name);
      if (!mounted) return;
      await _addTo(id, name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.66,
      ),
      decoration: const BoxDecoration(
        color: AppConstants.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '添加到歌单',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          Flexible(
            child: _error != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 13.5)),
                  )
                : _mine == null
                    ? const Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 20),
                        children: <Widget>[
                          ListTile(
                            leading: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: _creating
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2.2),
                                    )
                                  : const Icon(Icons.add_rounded, size: 24),
                            ),
                            title: const Text('新建歌单',
                                style: TextStyle(fontSize: 15)),
                            onTap: _creating ? null : _createNew,
                          ),
                          for (final NeteaseUserPlaylist p in _mine!)
                            ListTile(
                              leading: CoverImage(
                                  src: p.coverUrl, size: 44, radius: 8),
                              title: Text(p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15)),
                              subtitle: Text('${p.trackCount}首',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                              trailing: _busyId == p.id
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : null,
                              onTap:
                                  _busyId == null ? () => _addTo(p.id, p.name) : null,
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}
