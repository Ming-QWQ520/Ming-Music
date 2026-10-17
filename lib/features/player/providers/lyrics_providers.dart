/// 歌词状态层：拉取（/lyric/new）+ 解析（yrc 逐字 / LRC 回退）+ 翻译对齐。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_models.dart' show LyricData;
import '../../../core/utils/lyrics.dart';
import '../../../core/utils/yrc_lyrics.dart';
import '../../discover/data/netease_providers.dart'
    show neteaseRepositoryProvider;
import 'player_providers.dart' show PlayerState, playerProvider;

/// 已解析歌词（当前曲目）
class ParsedLyrics {
  const ParsedLyrics({
    this.yrcLines = const <YrcLine>[],
    this.lrcLines = const <LyricLine>[],
    this.translations = const <int, String>{},
  });

  /// 逐字歌词（空表示该曲无 yrc）
  final List<YrcLine> yrcLines;

  /// 逐行歌词（LRC 回退）
  final List<LyricLine> lrcLines;

  /// 翻译：毫秒时间戳 → 文本（与 lrcLines 时间轴对应）
  final Map<int, String> translations;

  bool get hasYrc => yrcLines.isNotEmpty;
  bool get hasLrc => lrcLines.isNotEmpty;
  bool get isEmpty => !hasYrc && !hasLrc;
}

/// 歌词原始数据（按网易云歌曲 id 缓存）
final FutureProviderFamily<LyricData, int> lyricDataProvider =
    FutureProvider.family<LyricData, int>((Ref ref, int songId) {
  return ref.read(neteaseRepositoryProvider).lyric(songId);
});

/// 当前曲目的已解析歌词
final Provider<ParsedLyrics> currentLyricsProvider =
    Provider<ParsedLyrics>((Ref ref) {
  final int? songId = ref.watch(
      playerProvider.select((PlayerState s) => s.currentTrack?.neteaseId));
  if (songId == null) return const ParsedLyrics();

  final AsyncValue<LyricData> async = ref.watch(lyricDataProvider(songId));
  return async.when<ParsedLyrics>(
    loading: () => const ParsedLyrics(),
    error: (Object e, StackTrace st) => const ParsedLyrics(),
    data: (LyricData data) {
      // 逐字歌词优先
      if (data.hasYrc) {
        final List<YrcLine> lines = parseYrc(data.yrcText!);
        if (lines.isNotEmpty) {
          return ParsedLyrics(yrcLines: lines);
        }
      }
      // LRC 回退 + 翻译对齐
      final Map<int, String> translations = <int, String>{};
      if (data.translationText != null && data.translationText!.isNotEmpty) {
        for (final LyricLine line in parseLrc(data.translationText!)) {
          translations[line.time.inMilliseconds] = line.text;
        }
      }
      final List<LyricLine> lines =
          data.hasLrc ? parseLrc(data.lrcText!) : const <LyricLine>[];
      return ParsedLyrics(
        lrcLines: lines,
        translations: translations,
      );
    },
  );
});
