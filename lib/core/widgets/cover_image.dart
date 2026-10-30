/// 统一封面组件：**仅内存缓存**（LRU 上限，会话内有效）+ 占位渐变。
///
/// 需求变更（2026-10-23）：**去除封面磁盘缓存** —— 用户反馈封面缓存
/// 「莫名地多」且无需离线复用，封面改为纯内存缓存（应用退出即释放），
/// 不再向磁盘写入任何图片文件。
///
/// 例外：通知栏封面（系统 MediaStyle 需要本地文件路径，且网易 CDN 会
/// 拒绝系统通知的直连请求）由 [NotificationArtCache] 提供一个**有界**
/// （最多 6 个文件、LRU 淘汰）的专用存储，不属于通用封面缓存。
///
/// 网易云封面 URL 支持 `?param=WxH` 缩略参数，按展示尺寸分级下载，
/// 大幅节省流量（列表 300px / 播放页 500px / 通知原图）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

import '../utils/platform_actions.dart';

enum CoverSize { small, large, original }

/// 歌单封面 Hero 标签（需求：点击歌单封面 → 歌单详情页大图 Hero 转场）。
/// 源（我的页宫格卡/列表行）与目标（歌单详情 _CoverHero）共用同一派生。
/// 仅在 id > 0 时使用，避免多个未知 id 产生同 tag 冲突。
String playlistCoverHeroTag(int? playlistId) => 'playlist-cover-$playlistId';

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
    this.keepOldWhileLoading = false,
  });

  /// 网易云 CDN 对 Dart 默认 User-Agent 直接返回 403（实测取证：
  /// `Dart/x.x (dart:io)` → 403，浏览器 UA → 200），封面/头像全灭的根因。
  /// 所有网易 CDN 图片/音频请求必须携带浏览器 UA（跨文件共用）。
  static const String kImageUserAgent =
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 网络封面 URL（http(s)）；asset 路径兼容保留；null 显示占位。
  final String? src;
  final double size;
  final double radius;
  final CoverSize coverSize;

  /// 需求「切换歌曲时不闪占位」：src 变化时保留旧图继续展示，
  /// 新图加载完成后再无缝替换（播放页背景/大封面专用；列表复用
  /// 场景不要开，避免短暂残留上一任条目的封面）。
  final bool keepOldWhileLoading;

  /// 拉取原图字节（供全屏查看/保存至本地使用，走同一套重试）
  static Future<Uint8List?> loadOriginalBytes(String? src) async {
    if (src == null || src.isEmpty || !src.startsWith('http')) return null;
    return fetchBytes(src, CoverSize.original);
  }

  /// 按字节嗅探图片 MIME（保存至相册需要）
  static String sniffMime(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'image/jpeg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    return 'image/webp';
  }

  @override
  State<CoverImage> createState() => _CoverImageState();
}

// ---------------------------------------------------------------- 内存缓存

/// 封面字节内存缓存（需求：去除封面磁盘缓存后的会话内缓存层）。
/// 简单 FIFO 上限淘汰：超过 [_maxEntries] 清掉最早写入的一半。
class _CoverMemoryCache {
  static const int _maxEntries = 192;

  static final Map<String, Uint8List> _mem = <String, Uint8List>{};

  static Uint8List? get(String key) => _mem[key];

  static void put(String key, Uint8List bytes) {
    if (_mem.length >= _maxEntries) {
      final List<String> stale = _mem.keys.take(_maxEntries ~/ 2).toList();
      for (final String k in stale) {
        _mem.remove(k);
      }
    }
    _mem[key] = bytes;
  }

  static void clear() => _mem.clear();
}

/// 并发去重（同一 URL 只发一次请求）
final Map<String, Future<Uint8List?>> _kInflight =
    <String, Future<Uint8List?>>{};

/// 内存缓存键（与 fetchBytes 完全一致；peek 同步查询用）
String _coverMemKey(String url, CoverSize size) {
  final String rawUrl =
      url.startsWith('http://') ? url.replaceFirst('http://', 'https://') : url;
  return '${size.param ?? 'raw'}:$rawUrl';
}

/// 同步查询内存缓存（不发起网络）：
/// 第十二批需求修复「滑动封面时闪烁显示默认占位图」—— 播放页封面在
/// 常规态（CoverArtView）与过渡态（_FrozenCover）之间切换时，
/// CoverImage 会重新挂载，旧实现的 _bytes 只能在异步 _load 完成后
/// 才有值，即使字节早已在内存缓存里也会先渲染 1～N 帧占位图。
/// 暴露同步 peek 后，initState/didUpdateWidget 可在首帧前同步水合。
Uint8List? peekCoverMemoryCache(String url, CoverSize size) =>
    _CoverMemoryCache.get(_coverMemKey(url, size));

/// 下载 + 并发去重 + 内存命中短路 + 多级重试。
///
/// 网易云 CDN 部分节点对 ?param 缩略参数会返回 403/404（部分歌曲封面无法
/// 加载的根因），按 缩略图 → 原图 → 小缩略图 三级重试。
Future<Uint8List?> fetchBytes(String url, CoverSize size) async {
  final String rawUrl = url.startsWith('http://')
      ? url.replaceFirst('http://', 'https://')
      : url; // CDN 明文直链统一 https（Android 9+ 拦截 http）

  final String memKey = _coverMemKey(url, size);
  final Uint8List? cached = _CoverMemoryCache.get(memKey);
  if (cached != null) return cached;

  // 重试阶梯：指定尺寸 → 原图 → 120 小图（部分特殊尺寸仅小图可访问）
  final List<String> candidates = <String>[
    if (size.param != null && !rawUrl.contains('?param='))
      '$rawUrl?param=${size.param}',
    rawUrl,
    if (!rawUrl.contains('?param=')) '$rawUrl?param=120y120',
  ];

  for (final String candidate in candidates) {
    final Uint8List? bytes = await _download(candidate);
    if (bytes != null) {
      _CoverMemoryCache.put(memKey, bytes);
      return bytes;
    }
  }
  return null;
}

Future<Uint8List?> _download(String sizedUrl) {
  return _kInflight.putIfAbsent(sizedUrl, () async {
    try {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      final HttpClientRequest req = await client.getUrl(Uri.parse(sizedUrl));
      req.headers.set(HttpHeaders.userAgentHeader, CoverImage.kImageUserAgent);
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
      scheduleMicrotask(() => _kInflight.remove(sizedUrl));
    }
  });
}

class _CoverImageState extends State<CoverImage> {
  Uint8List? _bytes;
  bool _failed = false;

  /// 需求修复「恢复网络后不自动获取歌单封面，需手动进出才显示」：
  /// 旧实现失败后 _failed 永久置位，网络恢复也不重试 —— 订阅原生
  /// 离线→在线事件，恢复时自动重拉（封面全局生效，不止我的页）
  StreamSubscription<dynamic>? _netSub;

  @override
  void initState() {
    super.initState();
    _hydrateFromMemoryCache();
    _load();
    _netSub = PlatformActions.networkRestoredStream().listen((_) {
      if (!mounted) return;
      if (_bytes != null) return;
      // 失败/加载中均重试（加载中重试无损：并发去重 + 内存命中短路）
      _failed = false;
      _load();
    });
  }

  @override
  void dispose() {
    _netSub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src) {
      // keepOldWhileLoading：旧图保留展示，等新图到达再替换（防闪占位）
      if (!widget.keepOldWhileLoading) {
        _bytes = null;
      }
      _failed = false;
      // 新地址若已在内存缓存，同步替换（不闪烁、不等异步）
      _hydrateFromMemoryCache();
      _load();
    }
  }

  /// 同步水合：内存缓存命中则直接赋值（initState 内可直接赋字段，
  /// 无需 setState；命中后首帧即渲染真图，消灭占位闪烁）
  void _hydrateFromMemoryCache() {
    final String? src = widget.src;
    if (src == null || src.isEmpty || !src.startsWith('http')) return;
    final Uint8List? cached = peekCoverMemoryCache(src, widget.coverSize);
    if (cached != null) {
      _bytes = cached;
      _failed = false;
    }
  }

  Future<void> _load() async {
    final String? src = widget.src;
    if (src == null || src.isEmpty || !src.startsWith('http')) return;
    final Uint8List? bytes = await fetchBytes(src, widget.coverSize);
    if (!mounted || src != widget.src) return;
    if (bytes != null) {
      setState(() => _bytes = bytes);
    } else if (mounted) {
      // 加载失败：仅在未开启保旧图时显示失败占位；保旧图时维持旧画面
      if (!widget.keepOldWhileLoading || _bytes == null) {
        setState(() => _failed = true);
      }
    }
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
    if (_bytes != null) {
      image = Image.memory(
        _bytes!,
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

// ------------------------------------------------ 通知栏封面（有界磁盘存储）

/// 通知栏封面专用存储（需求「去除封面缓存」的例外通道）：
///
/// 系统 MediaStyle 通知要求 artUri 指向本地文件（网易 CDN 会拒绝系统通知
/// 的直连请求 → 403 → 通知无封面）。本存储：
///  - 仅服务通知栏，目录独立（` caches/notif_art/`）；
///  - **有界**：最多保留 [maxFiles] 个文件，写入后按修改时间淘汰旧文件，
///    空间占用有硬上限（约 6 张原图），不再随浏览无限增长。
class NotificationArtCache {
  NotificationArtCache._();

  static const int maxFiles = 6;

  static Future<Directory>? _dirFuture;

  static Future<Directory> _dir() {
    return _dirFuture ??= () async {
      final Directory base = await getApplicationCacheDirectory();
      final Directory dir = Directory('${base.path}/notif_art');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }();
  }

  static String _fileName(String url) =>
      crypto.md5.convert(url.codeUnits).toString();

  /// 取通知栏封面文件：磁盘命中直接用；未命中下载（原图 → 500y500）后落盘。
  /// 失败返回 null（调用方回退网络 URL）。
  static Future<File?> fileFor(String? src) async {
    if (src == null || src.isEmpty || !src.startsWith('http')) return null;
    try {
      final Directory dir = await _dir();
      final File done = File('${dir.path}/${_fileName(src)}');
      if (done.existsSync() && done.lengthSync() > 0) {
        return done;
      }
      Uint8List? bytes = await fetchBytes(src, CoverSize.original);
      bytes ??= await fetchBytes(src, CoverSize.large);
      if (bytes == null || bytes.isEmpty) return null;
      await done.writeAsBytes(bytes, flush: true);
      unawaited(_prune(dir));
      return done;
    } catch (_) {
      return null;
    }
  }

  /// LRU 收敛：超过 maxFiles 删除最旧文件
  static Future<void> _prune(Directory dir) async {
    try {
      final List<FileSystemEntity> files = dir
          .listSync()
          .whereType<File>()
          .toList()
        ..sort((FileSystemEntity a, FileSystemEntity b) => File(a.path)
            .lastModifiedSync()
            .compareTo(File(b.path).lastModifiedSync()));
      for (int i = 0; i < files.length - maxFiles; i++) {
        try {
          files[i].deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 占用统计（设置/我的页缓存展示）
  static Future<int> sizeBytes() async {
    try {
      final Directory dir = await _dir();
      if (!dir.existsSync()) return 0;
      return dir
          .listSync()
          .whereType<File>()
          .fold<int>(0, (int acc, File f) => acc + f.lengthSync());
    } catch (_) {
      return 0;
    }
  }

  /// 清理（清缓存入口）
  static Future<void> clear() async {
    _CoverMemoryCache.clear();
    try {
      final Directory dir = await _dir();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
