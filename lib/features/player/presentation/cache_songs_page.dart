/// 缓存音乐列表页（需求：点击数据缓存可查看缓存的音乐）：
///  - 展示已缓存音频：封面 / 歌名 / 歌手 / 音质档 / 大小 / 缓存时间；
///  - 点击整行 → 直接播放该缓存歌曲（离线可用：播放解析缓存优先）；
///  - 行尾删除单条；顶栏清空全部（确认对话框）；
///  - 旧版本缓存无元信息时以「歌曲 id」兜底显示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/cover_image.dart';
import '../../library/domain/track.dart';
import '../providers/cache_providers.dart';
import '../../settings/providers/settings_providers.dart'
    show listenCacheProvider, cacheLimitProvider;
import '../providers/player_providers.dart';
import '../services/song_cache.dart';

class CacheSongsPage extends ConsumerWidget {
  const CacheSongsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<CacheEntry>> async = ref.watch(cacheEntriesProvider);
    final bool listenCache = ref.watch(listenCacheProvider);
    final int cacheLimit = ref.watch(cacheLimitProvider);

    final int totalBytes = (async.valueOrNull ?? const <CacheEntry>[])
        .fold<int>(0, (int a, CacheEntry e) => a + e.sizeBytes);

    return Scaffold(
      backgroundColor: AppConstants.darkScaffold,
      appBar: AppBar(
        title: const Text('缓存音乐',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: <Widget>[
          if ((async.valueOrNull ?? const <CacheEntry>[]).isNotEmpty)
            IconButton(
              tooltip: '清空缓存',
              icon: const Icon(Icons.delete_sweep_outlined, size: 22),
              onPressed: () => _clearAll(context, ref),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: <Widget>[
          // 需求：LRU 缓存上限设置 —— 默认 3GB，可自行更改；
          // 缓存总开关关闭时弹确认弹窗（颜文字文案）
          _CacheLimitPanel(listenCache: listenCache),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Row(
              children: <Widget>[
                Icon(Icons.info_outline_rounded,
                    size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '${async.valueOrNull?.length ?? 0} 首 · 共 ${_fmtSize(totalBytes)}'
                    ' · 上限 ${_fmtSize(cacheLimit)}，已缓存歌曲离线也能播放',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.6),
                ),
              ),
              error: (Object e, StackTrace st) => Center(
                child: Text('加载失败：$e',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 13)),
              ),
              data: (List<CacheEntry> entries) {
                if (entries.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(Icons.library_music_outlined,
                            size: 46,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(height: 10),
                        Text('暂无缓存歌曲',
                            style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 14)),
                        const SizedBox(height: 4),
                        Text('播放过的歌曲会自动缓存到此处',
                            style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                                fontSize: 12)),
                      ],
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async =>
                      ref.refresh(cacheEntriesProvider.future),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: entries.length,
                    itemBuilder: (BuildContext ctx, int i) {
                      final CacheEntry e = entries[i];
                      return _CacheRow(
                        entry: e,
                        onDelete: () => _remove(context, ref, e),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, CacheEntry e) async {
    await ref.read(songCacheProvider).removeEntry(e.key);
    ref.invalidate(cacheEntriesProvider);
    ref.invalidate(cachedSongIdsProvider);
  }

  Future<void> _clearAll(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('清空缓存音乐'),
        content: const Text('将删除全部已缓存的歌曲音频，清理后离线将无法播放这些歌曲，确定继续吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(songCacheProvider).clearAll();
    ref.invalidate(cacheEntriesProvider);
    ref.invalidate(cachedSongIdsProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('缓存已清空')));
  }

  static String _fmtSize(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

// ---------------------------------------------------------------- 行

class _CacheRow extends ConsumerWidget {
  const _CacheRow({required this.entry, required this.onDelete});

  final CacheEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: () async {
        // 播放缓存歌曲：直接以本地缓存文件为播放源（离线可用、秒开），
        // 保留 neteaseId 以维持歌词/红心/通知栏等完整体验
        final Track track = Track(
          id: 'netease_${entry.songId}',
          neteaseId: entry.songId,
          title: entry.displayTitle,
          artist: entry.displayArtist,
          album: '',
          source: entry.path,
          cover: entry.cover.isEmpty ? null : entry.cover,
          durationMs: null,
          isNetwork: false,
          isCustom: false,
        );
        Navigator.of(context).pop();
        await ref.read(playerProvider.notifier).playSongs(
          <Track>[track],
          queueTitle: '缓存音乐',
        );
      },
      onLongPress: onDelete,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <Widget>[
            CoverImage(
                src: entry.cover.isEmpty ? null : entry.cover,
                size: 46,
                radius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${entry.displayArtist} · ${_levelName(entry.level)}'
                    ' · ${_fmtSize(entry.sizeBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除缓存',
              icon: Icon(Icons.close_rounded,
                  size: 19, color: theme.colorScheme.onSurfaceVariant),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }

  static String _levelName(String level) => switch (level) {
        'standard' => '标准',
        'higher' => '较高',
        'exhigh' => '极高',
        'lossless' => '无损',
        'hires' => 'Hi-Res',
        'jyeffect' => '高清环绕声',
        'sky' => '沉浸环绕声',
        'jymaster' => '超清母带',
        _ => level,
      };

  static String _fmtSize(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 缓存上限设置面板（需求：LRU 默认 3GB，可自行更改；可关闭缓存，
/// 关闭时弹确认弹窗 —— 关闭后没网不能听歌了哦）
class _CacheLimitPanel extends ConsumerWidget {
  const _CacheLimitPanel({required this.listenCache});

  final bool listenCache;

  /// 滑杆范围：0.5GB - 10GB
  static const double _kMinGb = 0.5;
  static const double _kMaxGb = 10;

  static String _fmtGb(double gb) => gb == gb.roundToDouble()
      ? '${gb.toInt()} GB'
      : '${gb.toStringAsFixed(1)} GB';

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool v) async {
    if (v) {
      ref.read(listenCacheProvider.notifier).set(true);
      return;
    }
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('关闭边听边缓存'),
        content: const Text('关闭后没网不能听歌了哦(๑`^´๑)，真的要关吗'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("算了(●'◡'●)"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('关闭╥_╥'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      ref.read(listenCacheProvider.notifier).set(false);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int cacheLimit = ref.watch(cacheLimitProvider);
    final double gb =
        (cacheLimit / (1024 * 1024 * 1024)).clamp(_kMinGb, _kMaxGb);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('最大缓存容量',
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
              Text(_fmtGb(gb),
                  style: TextStyle(
                      fontSize: 12.5,
                      color: AppConstants.brandColor,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: ((gb - _kMinGb) / (_kMaxGb - _kMinGb)).clamp(0.0, 1.0),
              activeColor: AppConstants.brandColor,
              onChanged: listenCache
                  ? (double v) {
                      final double next = _kMinGb + v * (_kMaxGb - _kMinGb);
                      // 步进 0.5GB
                      final double stepped = (next * 2).roundToDouble() / 2;
                      ref.read(cacheLimitProvider.notifier).set(
                            (stepped * 1024 * 1024 * 1024).round(),
                          );
                    }
                  : null,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: const Text('边听边缓存', style: TextStyle(fontSize: 14)),
            subtitle: Text(listenCache ? '播放的歌曲自动缓存，离线可听' : '已关闭：无网将无法播放未缓存歌曲',
                style: const TextStyle(fontSize: 11.5)),
            value: listenCache,
            activeThumbColor: AppConstants.brandColor,
            onChanged: (bool v) => _toggle(context, ref, v),
          ),
        ],
      ),
    );
  }
}
