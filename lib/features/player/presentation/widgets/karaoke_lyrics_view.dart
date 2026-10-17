/// 歌词视图（逐字优先 / 逐行回退）：
///  - yrc：当前行内逐字着色（唱过亮白、未唱暗灰）；
///  - LRC：当前行高亮 + 翻译副行；
///  - 自动滚动居中，手动滚动后 4 秒内暂停跟随（滚动抑制，避坑指南 4）；
///  - 点击任意行 seek 到该行起始时间。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/lyrics.dart';
import '../../../../core/utils/yrc_lyrics.dart';
import '../../providers/lyrics_providers.dart';
import '../../providers/player_providers.dart';

class KaraokeLyricsView extends ConsumerStatefulWidget {
  const KaraokeLyricsView({super.key, this.lineExtent});

  /// 统一行高（元数据行与歌词行同高，保证 animateTo 偏移精确）
  final double? lineExtent;

  @override
  ConsumerState<KaraokeLyricsView> createState() => _KaraokeLyricsViewState();
}

class _KaraokeLyricsViewState extends ConsumerState<KaraokeLyricsView> {
  final ScrollController _scroll = ScrollController();
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastActive = -2;

  double get _extent => widget.lineExtent ?? AppConstants.yrcLineExtent;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int active) {
    if (active == _lastActive) return;
    _lastActive = active;
    if (active < 0) return;
    if (DateTime.now().isBefore(_suppressUntil)) return;
    if (!_scroll.hasClients) return;

    final double viewport = _scroll.position.viewportDimension;
    final double target = (active * _extent - viewport / 2 + _extent / 2)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  void _onUserScroll() {
    _suppressUntil = DateTime.now().add(AppConstants.lyricScrollSuppression);
  }

  @override
  Widget build(BuildContext context) {
    final ParsedLyrics lyrics = ref.watch(currentLyricsProvider);

    if (lyrics.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 15,
          ),
        ),
      );
    }

    final Duration position =
        ref.watch(positionProvider).value ?? Duration.zero;

    if (lyrics.hasYrc) {
      final List<YrcLine> lines = lyrics.yrcLines;
      final int active = activeYrcIndex(lines, position);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeAutoScroll(active);
      });
      return _wrapScroll(
        ListView.builder(
          controller: _scroll,
          itemExtent: _extent,
          itemCount: lines.length,
          itemBuilder: (BuildContext context, int index) => _YrcRow(
            line: lines[index],
            position: position,
            active: index == active,
            onSeek: _seek,
          ),
        ),
      );
    }

    final List<LyricLine> lines = lyrics.lrcLines;
    final int active = activeLyricIndex(lines, position);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoScroll(active);
    });
    return _wrapScroll(
      ListView.builder(
        controller: _scroll,
        itemExtent: _extent,
        itemCount: lines.length,
        itemBuilder: (BuildContext context, int index) => _LrcRow(
          line: lines[index],
          translation:
              lyrics.translations[lines[index].time.inMilliseconds] ?? '',
          active: index == active,
          onSeek: _seek,
        ),
      ),
    );
  }

  void _seek(Duration time) {
    ref.read(playerProvider.notifier).seek(time);
  }

  Widget _wrapScroll(Widget child) {
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        // 用户拖动即判定为手动滚动，抑制自动跟随
        final bool dragged =
            (n is ScrollStartNotification && n.dragDetails != null) ||
                (n is ScrollUpdateNotification && n.dragDetails != null);
        if (dragged) {
          _onUserScroll();
        }
        return false;
      },
      child: child,
    );
  }
}

// ---------------------------------------------------------------- rows

/// 逐字行：行内每个字按已唱/未唱着色
class _YrcRow extends StatelessWidget {
  const _YrcRow({
    required this.line,
    required this.position,
    required this.active,
    required this.onSeek,
  });

  final YrcLine line;
  final Duration position;
  final bool active;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final bool metadata = line.isMetadata;

    final Color baseColor = metadata
        ? Colors.white.withValues(alpha: 0.28)
        : Colors.white.withValues(alpha: 0.40);
    final Color sungColor =
        metadata ? Colors.white.withValues(alpha: 0.60) : Colors.white;
    final double fontSize = metadata ? 13.5 : 17;

    final List<InlineSpan> spans = <InlineSpan>[];
    for (final YrcWord w in line.words) {
      final bool sung =
          position >= w.end || (active && w.progress(position) > 0);
      spans.add(
        TextSpan(
          text: w.text,
          style: TextStyle(
            color: sung ? sungColor : baseColor,
            fontSize: fontSize,
            fontWeight: active && !metadata ? FontWeight.w700 : FontWeight.w500,
            height: 1.25,
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: metadata ? null : () => onSeek(line.start),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(children: spans),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// 逐行行（LRC 回退）：当前行白 + 翻译副行
class _LrcRow extends StatelessWidget {
  const _LrcRow({
    required this.line,
    required this.translation,
    required this.active,
    required this.onSeek,
  });

  final LyricLine line;
  final String translation;
  final bool active;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onSeek(line.time),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              line.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.40),
                fontSize: active ? 17 : 15.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            if (translation.isNotEmpty)
              Text(
                translation,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active
                      ? Colors.white.withValues(alpha: 0.72)
                      : Colors.white.withValues(alpha: 0.26),
                  fontSize: 12.5,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
