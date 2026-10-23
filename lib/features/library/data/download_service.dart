/// 歌曲下载服务：解析直链 → 拉取音频字节 → MediaStore 音乐目录。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart' show SongUrlInfo;
import '../../../core/utils/platform_actions.dart';
import '../../discover/data/netease_providers.dart';
import '../../settings/domain/settings_models.dart' show AudioQualityX;
import '../../settings/providers/settings_providers.dart'
    show audioQualityProvider;
import '../domain/track.dart';

class DownloadResult {
  const DownloadResult(this.ok, this.message);

  final bool ok;
  final String message;
}

/// 下载单曲。已解析直链（track.source）直接用；网易云曲目按当前音质重解析。
Future<DownloadResult> downloadTrack(WidgetRef ref, Track track) async {
  String? url = track.source.startsWith('http') ? track.source : null;
  if (url == null && track.neteaseId != null) {
    try {
      final String level = ref.read(audioQualityProvider).apiValue;
      final List<SongUrlInfo> urls = await ref
          .read(neteaseRepositoryProvider)
          .songUrls(<int>[track.neteaseId!], level: level);
      if (urls.isNotEmpty) url = urls.first.url;
    } catch (e) {
      return DownloadResult(false, '获取下载链接失败：$e');
    }
  }
  if (url == null || url.isEmpty) {
    return DownloadResult(false, '该歌曲暂无可用下载链接');
  }
  final Uint8List? bytes = await PlatformActions.downloadBytes(url);
  if (bytes == null) {
    return DownloadResult(false, '下载失败，请检查网络');
  }
  final bool ok = await PlatformActions.saveAudio(
    name: '${track.title} - ${track.artist}',
    mime: PlatformActions.audioMimeOf(null, url),
    bytes: bytes,
  );
  return ok
      ? const DownloadResult(true, '已保存到 Music/MingMusic')
      : const DownloadResult(false, '保存失败（存储不可用）');
}
