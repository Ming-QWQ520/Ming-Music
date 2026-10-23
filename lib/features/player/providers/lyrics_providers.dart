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
///
/// 注意：构造时会对翻译/音译时间戳排序（就近匹配用），因此不可为
/// const 构造 —— 默认空对象统一用 [ParsedLyrics.empty]。
class ParsedLyrics {
  ParsedLyrics({
    this.yrcLines = const <YrcLine>[],
    this.lrcLines = const <LyricLine>[],
    this.translations = const <int, String>{},
    this.romanizations = const <int, String>{},
  })  : _transKeys = translations.keys.toList()..sort(),
        _romaKeys = romanizations.keys.toList()..sort();

  /// 默认空对象（歌词未加载/加载失败/无曲目）
  static final ParsedLyrics empty = ParsedLyrics();

  /// 逐字歌词（空表示该曲无 yrc）
  final List<YrcLine> yrcLines;

  /// 逐行歌词（LRC 回退）
  final List<LyricLine> lrcLines;

  /// 翻译：毫秒时间戳 → 文本（与 lrcLines 时间轴对应）
  final Map<int, String> translations;

  /// 音译（romalrc，粤语/日语拼音）：毫秒时间戳 → 文本
  final Map<int, String> romanizations;

  /// 排序后的翻译/音译时间戳（就近匹配用，构造时一次生成）
  final List<int> _transKeys;
  final List<int> _romaKeys;

  bool get hasYrc => yrcLines.isNotEmpty;
  bool get hasLrc => lrcLines.isNotEmpty;
  bool get isEmpty => !hasYrc && !hasLrc;

  /// 就近匹配允许的最大时间偏差（毫秒）。
  /// 修复「部分外语歌不显示翻译」：不少歌曲的 tlyric/romalrc 时间轴与
  /// 原文行存在几十至几百毫秒的整体偏移，精确匹配会整曲 miss。
  static const int _nearbyToleranceMs = 600;

  /// 在排序键 [keys] 中二分查找与 [ms] 最近的键（无键返回 null）
  static int? _nearestKey(List<int> keys, int ms) {
    if (keys.isEmpty) return null;
    int lo = 0, hi = keys.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (keys[mid] < ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    int best = keys[lo];
    if (lo > 0 && (keys[lo - 1] - ms).abs() < (best - ms).abs()) {
      best = keys[lo - 1];
    }
    return best;
  }

  /// 副行文案（仿网易云：有翻译用翻译，无翻译用音译拼音）。
  /// 先精确匹配，未命中则就近匹配（≤600ms）—— 与网易云客户端对齐。
  String subLineFor(int ms) {
    final String exact = translations[ms] ?? romanizations[ms] ?? '';
    if (exact.isNotEmpty) return exact;
    final int? tk = _nearestKey(_transKeys, ms);
    if (tk != null && (tk - ms).abs() <= _nearbyToleranceMs) {
      final String t = translations[tk] ?? '';
      if (t.isNotEmpty) return t;
    }
    final int? rk = _nearestKey(_romaKeys, ms);
    if (rk != null && (rk - ms).abs() <= _nearbyToleranceMs) {
      return romanizations[rk] ?? '';
    }
    return '';
  }
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
  if (songId == null) return ParsedLyrics.empty;

  final AsyncValue<LyricData> async = ref.watch(lyricDataProvider(songId));
  return async.when<ParsedLyrics>(
    loading: () => ParsedLyrics.empty,
    error: (Object e, StackTrace st) => ParsedLyrics.empty,
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
