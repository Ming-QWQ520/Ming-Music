/// MV 播放页（闭环：song.mv → /mv/detail 详情 + /mv/url 直链 → 播放）：
///  - 全屏黑底视频 + 顶部返回/标题；
///  - 底部信息：MV 名/艺人/播放量 + 进度条控制（video_player 控制器）；
///  - 直链约 1 小时过期（expi:3600），进入页面即时获取；
///  - http 直链经 normalizeNeteaseUrl 改写 https（vod 域名已纳入覆盖）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/constants/app_constants.dart';
import '../../discover/data/netease_providers.dart'
    show neteaseRepositoryProvider;

/// 打开 MV 播放页（信息加载失败时用 fallbackTitle 兜底）
Future<void> openMvPlayer(
  BuildContext context, {
  required int mvId,
  required String fallbackTitle,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext _) =>
          MvPlayerPage(mvId: mvId, fallbackTitle: fallbackTitle),
    ),
  );
}

class MvPlayerPage extends ConsumerStatefulWidget {
  const MvPlayerPage({super.key, required this.mvId, required this.fallbackTitle});

  final int mvId;
  final String fallbackTitle;

  @override
  ConsumerState<MvPlayerPage> createState() => _MvPlayerPageState();
}

class _MvPlayerPageState extends ConsumerState<MvPlayerPage> {
  VideoPlayerController? _controller;
  String _title = '';
  String _artist = '';
  int _playCount = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 详情与地址并行：标题/播放量 + 直链（闭环两接口缺一不可）
      final repo = ref.read(neteaseRepositoryProvider);
      final results =
          await Future.wait<Object?>(<Future<Object?>>[
        repo.mvDetail(widget.mvId),
        repo.mvUrl(widget.mvId),
      ]);
      final dynamic detail = results[0];
      final dynamic urlInfo = results[1];
      final String url = urlInfo.url as String;
      if (url.isEmpty) {
        throw Exception('该 MV 暂无可播放的地址（版权或地区限制）');
      }
      final VideoPlayerController controller =
          VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.play();
      setState(() {
        _controller = controller;
        _title = detail.name as String;
        _artist = detail.artistName as String;
        _playCount = detail.playCount as int;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'MV 加载失败：$e';
      });
    }
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controller?.dispose();
    super.dispose();
  }

  String _formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  String _formatDuration(Duration d) {
    final String mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // 顶栏
            SizedBox(
              height: 48,
              child: Row(
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded,
                        color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(
                      _title.isEmpty ? widget.fallbackTitle : _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            // 视频区
            Expanded(child: Center(child: _buildVideo())),
            // 底部信息
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              color: Colors.white.withValues(alpha: 0.04),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _title.isEmpty ? widget.fallbackTitle : _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _artist.isEmpty ? '—' : _artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 13),
                        ),
                      ),
                      Icon(Icons.play_arrow_rounded,
                          size: 15, color: Colors.white.withValues(alpha: 0.55)),
                      const SizedBox(width: 2),
                      Text(
                        '${_formatCount(_playCount)}次播放',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildControlRow(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    if (_loading) {
      return const CircularProgressIndicator(
          strokeWidth: 2.4, color: AppConstants.brandColor);
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.videocam_off_rounded,
              size: 44, color: Colors.white.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
            ),
          ),
        ],
      );
    }
    final VideoPlayerController? c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return AspectRatio(
      aspectRatio: c.value.aspectRatio,
      child: VideoPlayer(c),
    );
  }

  Widget _buildControlRow() {
    final VideoPlayerController? c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: c,
      builder: (BuildContext context, Widget? _) {
        final Duration pos = c.value.position;
        final Duration dur = c.value.duration;
        final double progress = dur.inMilliseconds > 0
            ? pos.inMilliseconds / dur.inMilliseconds
            : 0;
        return Row(
          children: <Widget>[
            GestureDetector(
              onTap: () {
                if (c.value.isPlaying) {
                  c.pause();
                } else {
                  c.play();
                }
              },
              child: Icon(
                c.value.isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_filled_rounded,
                color: Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDuration(pos),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7), fontSize: 11),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: progress.clamp(0.0, 1.0),
                  activeColor: AppConstants.brandColor,
                  onChanged: (double v) {
                    c.seekTo(dur * v);
                  },
                ),
              ),
            ),
            Text(
              _formatDuration(dur),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7), fontSize: 11),
            ),
          ],
        );
      },
    );
  }
}
