/// 统一封面组件：网络封面磁盘缓存（md5 命名 + 并发去重）/ 占位渐变。
///
/// 网易云封面 URL 支持 `?param=WxH` 缩略参数，按展示尺寸分级下载，
/// 大幅节省流量（列表 300px / 播放页 500px / 模糊背景原图）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

enum CoverSize { small, large, original }

extension CoverSizeX on CoverSize {
  /// 网易云图片缩略参数；null = 原图
  String? get param => switch (this) {
        CoverSize.small => '300y300',
        CoverSize.large => '500y500',
        CoverSize.original => null,
      };
}

class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    this.src,
    this.size = 48,
    this.radius = 12,
    this.coverSize = CoverSize.small,
  });

  /// 网络封面 URL（http(s)）；asset 路径兼容保留；null 显示占位。
  final String? src;
  final double size;
  final double radius;
  final CoverSize coverSize;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  File? _cachedFile;
  bool _failed = false;

  static final Map<String, Future<Uint8List?>> _inflight =
      <String, Future<Uint8List?>>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src) {
      _cachedFile = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final String? src = widget.src;
    if (src == null || src.isEmpty || !src.startsWith('http')) return;
    final Uint8List? bytes = await _fetchBytes(src, widget.coverSize);
    if (!mounted || src != widget.src) return;
    if (bytes != null) {
      final Directory dir = await _cacheDir();
      final String key = _fileName(src, widget.coverSize);
      final File file = File('${dir.path}/$key');
      if (!file.existsSync()) {
        await file.writeAsBytes(bytes, flush: true);
      }
      if (!mounted || src != widget.src) return;
      setState(() => _cachedFile = file);
    } else if (mounted) {
      setState(() => _failed = true);
    }
  }

  static Future<Directory> _cacheDir() async {
    final Directory base = await getApplicationCacheDirectory();
    final Directory dir = Directory('${base.path}/covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _fileName(String url, CoverSize size) {
    final String key = '${size.param ?? 'raw'}:$url';
    return crypto.md5.convert(key.codeUnits).toString();
  }

  /// 下载 + 并发去重 + 磁盘命中短路
  static Future<Uint8List?> _fetchBytes(String url, CoverSize size) async {
    try {
      final Directory dir = await _cacheDir();
      final File file = File('${dir.path}/${_fileName(url, size)}');
      if (file.existsSync()) {
        final Uint8List existing = await file.readAsBytes();
        if (existing.isNotEmpty) return existing;
      }
    } catch (_) {}

    final String param = size.param ?? '';
    final String sizedUrl = url.contains('?param=')
        ? url
        : (param.isEmpty ? url : '$url?param=$param');

    return _inflight.putIfAbsent(sizedUrl, () async {
      try {
        final HttpClient client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        final HttpClientRequest req = await client.getUrl(Uri.parse(sizedUrl));
        final HttpClientResponse resp = await req.close();
        if (resp.statusCode != 200) {
          await resp.drain<Object?>();
          return null;
        }
        final Uint8List bytes = Uint8List.fromList(
          await resp.fold<List<int>>(
            <int>[],
            (List<int> acc, List<int> chunk) => acc..addAll(chunk),
          ),
        );
        return bytes.isEmpty ? null : bytes;
      } catch (e) {
        debugPrint('封面下载失败 $sizedUrl: $e');
        return null;
      } finally {
        scheduleMicrotask(() => _inflight.remove(sizedUrl));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget placeholder = Container(
      width: widget.size,
      height: widget.size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF3A3352), Color(0xFF221E38)],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        size: widget.size * 0.42,
        color: Colors.white.withValues(alpha: 0.5),
      ),
    );

    Widget image;
    if (_cachedFile != null) {
      image = Image.file(
        _cachedFile!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
      );
    } else if (_failed || widget.src == null || widget.src!.isEmpty) {
      image = placeholder;
    } else if (!widget.src!.startsWith('http')) {
      image = Image.asset(
        widget.src!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
      );
    } else {
      image = placeholder; // 网络加载中
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: image,
    );
  }
}
