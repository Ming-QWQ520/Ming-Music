/// 滚动歌词视图：
///  - positionStream + 二分查找计算高亮行（O(log n)）；
///  - ScrollController.animateTo 平滑滚动到当前行居中；
///  - 用户手动滚动后暂停自动跟随（NotificationListener 检测）；
///  - ListView 自带逐项 RepaintBoundary，只有可见行参与重绘。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/lyrics.dart';
import '../../../library/domain/track.dart';
import '../../providers/player_providers.dart';

/// 歌词内容源：按歌词 asset 路径缓存解析结果
final FutureProviderFamily<List<LyricLine>, String> lyricsProvider =
    FutureProvider.family<List<LyricLine>, String>(
  (Ref ref, String asset) async {
    final String raw = await rootBundle.loadString(asset);
    return parseLrc(raw);
  },
);

class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({super.key, this.dense = false});

  /// 平板右栏使用更紧凑的行高
  final bool dense;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  final ScrollController _scrollController = ScrollController();
  DateTime _lastUserScroll = DateTime.fromMillisecondsSinceEpoch(0);
  int _activeIndex = -1;

  double get _lineExtent => widget.dense
      ? AppConstants.lyricLineExtent * 0.82
      : AppConstants.lyricLineExtent;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String? asset = track?.lyricsAsset;

    if (asset == null) {
      return _placeholder('纯音乐 · 请尽情聆听');
    }

    final AsyncValue<List<LyricLine>> asyncLines =
        ref.watch(lyricsProvider(asset));

    return asyncLines.when(
      loading: () => const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      ),
      error: (Object e, StackTrace st) => _placeholder('歌词加载失败'),
      data: (List<LyricLine> lines) {
        if (lines.isEmpty) return _placeholder('纯音乐 · 请尽情聆听');
        return _buildList(lines);
      },
    );
  }

  Widget _buildList(List<LyricLine> lines) {
    // 高频位置更新：ref.listen 不触发本组件整体 rebuild，
    // 仅当 activeIndex 变化时 setState（最小重绘原则）
    ref.listen<AsyncValue<Duration>>(positionProvider,
        (AsyncValue<Duration>? prev, AsyncValue<Duration> next) {
      final Duration position = next.value ?? Duration.zero;
      final int index = activeLyricIndex(lines, position);
      if (index != _activeIndex) {
        setState(() => _activeIndex = index);
        _scrollToIndex(index);
      }
    });

    // 初次进入时的定位（仅一次）
    if (_activeIndex == -1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _activeIndex != -1) return;
        final Duration? position = ref.read(positionProvider).value;
        if (position == null) return;
        final int index = activeLyricIndex(lines, position);
        if (index >= 0 && mounted) {
          setState(() => _activeIndex = index);
        }
      });
    }

    return NotificationListener<UserScrollNotification>(
      onNotification: (UserScrollNotification n) {
        if (n.direction != ScrollDirection.idle) {
          _lastUserScroll = DateTime.now();
        }
        return false;
      },
      child: ShaderMask(
        // 顶底淡出遮罩，静态层不参与重绘
        shaderCallback: (Rect bounds) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: 0.0),
            Colors.white,
            Colors.white,
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const <double>[0, 0.12, 0.86, 1],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView.builder(
          controller: _scrollController,
          itemCount: lines.length,
          itemExtent: _lineExtent,
          padding: EdgeInsets.symmetric(
            vertical: MediaQuery.sizeOf(context).height * 0.18,
            horizontal: 24,
          ),
          itemBuilder: (BuildContext context, int i) {
            final bool active = i == _activeIndex;
            return _LyricLineTile(
              text: lines[i].text,
              active: active,
              extent: _lineExtent,
              onTap: () =>
                  ref.read(playerProvider.notifier).seek(lines[i].time),
            );
          },
        ),
      ),
    );
  }

  void _scrollToIndex(int index) {
    if (index < 0 || !_scrollController.hasClients) return;
    // 用户刚手动滚动过 → 暂停自动跟随
    if (DateTime.now().difference(_lastUserScroll) <
        AppConstants.lyricScrollSuppression) {
      return;
    }
    final double viewport = _scrollController.position.viewportDimension;
    final double maxExtent = _scrollController.position.maxScrollExtent;
    final double target = (index * _lineExtent + _lineExtent / 2 - viewport / 2)
        .clamp(0.0, maxExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _placeholder(String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.music_note_outlined,
              size: 34, color: Colors.white.withValues(alpha: 0.35)),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- line tile

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    required this.text,
    required this.active,
    required this.extent,
    required this.onTap,
  });

  final String text;
  final bool active;
  final double extent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: extent,
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: active ? 19 : 16,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.42),
                letterSpacing: active ? 0.4 : 0.1,
                height: 1.3,
              ),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
