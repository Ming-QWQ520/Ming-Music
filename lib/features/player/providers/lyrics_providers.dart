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
    this.romanizations = const <int, String>{},
  });

  /// 逐字歌词（空表示该曲无 yrc）
  final List<YrcLine> yrcLines;

  /// 逐行歌词（LRC 回退）
  final List<LyricLine> lrcLines;

  /// 翻译：毫秒时间戳 → 文本（与 lrcLines 时间轴对应）
  final Map<int, String> translations;

  /// 音译（romalrc，粤语/日语拼音）：毫秒时间戳 → 文本
  final Map<int, String> romanizations;

  bool get hasYrc => yrcLines.isNotEmpty;
  bool get hasLrc => lrcLines.isNotEmpty;
  bool get isEmpty => !hasYrc && !hasLrc;

  /// 副行文案（仿网易云：有翻译用翻译，无翻译用音译拼音）
  String subLineFor(int ms) => translations[ms] ?? romanizations[ms] ?? '';
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
      // 翻译/音译对 yrc 与 lrc 两种形态都解析（修复英文歌无中文翻译：
      // 此前 yrc 分支提前 return 丢弃 tlyric）
      Map<int, String> translationsOf() {
        if (data.translationText == null ||
            data.translationText!.isEmpty) {
          return const <int, String>{};
        }
        final Map<int, String> out = <int, String>{};
        for (final LyricLine line in parseLrc(data.translationText!)) {
          out[line.time.inMilliseconds] = line.text;
        }
        return out;
      }

      Map<int, String> romanizationsOf() {
        if (data.romanizationText == null ||
            data.romanizationText!.isEmpty) {
          return const <int, String>{};
        }
        final Map<int, String> out = <int, String>{};
        for (final LyricLine line in parseLrc(data.romanizationText!)) {
          out[line.time.inMilliseconds] = line.text;
        }
        return out;
      }

      // 逐字歌词优先
      if (data.hasYrc) {
        final List<YrcLine> lines = parseYrc(data.yrcText!);
        if (lines.isNotEmpty) {
          return ParsedLyrics(
            yrcLines: lines,
            translations: translationsOf(),
            romanizations: romanizationsOf(),
          );
        }
      }
      final List<LyricLine> lines =
          data.hasLrc ? parseLrc(data.lrcText!) : const <LyricLine>[];
      return ParsedLyrics(
        lrcLines: lines,
        translations: translationsOf(),
        romanizations: romanizationsOf(),
      );
    },
  );
});
