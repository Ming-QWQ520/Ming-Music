/// 应用内自动更新服务（第十七批需求）。
///
/// 流程（对齐需求逐条实现）：
///  - 每次进入 App 后请求一次 Releases API（`/releases/latest`），
///    直连失败自动换 gh-proxy.com 镜像（第十六批已验证的通路）；
///  - 版本号比对：远端 tag（v1.2.3 / 1.2.3）> 当前版本（package_info_plus）
///    时视为有更新；
///  - 「立即更新」：按机型 ABI（device_info_plus supportedAbis）挑选
///    适配的 APK 资产，流式下载并回报进度，完成后经 open_filex 拉起
///    系统安装器；无对应 ABI 资产时回退唯一 APK / 通用名 APK；
///  - 「跳过」：仅关闭弹窗（下次启动仍然提示）；
///  - 「跳过此版本」：记录该 tag，之后不再提示（检查更新仍可手动触发）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/app_constants.dart';

/// 一个 GitHub Release 的轻量模型
class AppRelease {
  const AppRelease({
    required this.tagName,
    required this.title,
    required this.body,
    required this.publishedAt,
    required this.assets,
  });

  /// 版本标签（如 v1.2.3）
  final String tagName;

  /// 发布标题
  final String title;

  /// 发布说明（Markdown 原文，更新弹窗/版本更新日志渲染用）
  final String body;

  /// 发布时间（ISO 8601，可能为空）
  final String? publishedAt;

  /// 附件（APK 资产）
  final List<AppReleaseAsset> assets;

  static AppRelease? fromJson(Map<String, Object?> j) {
    final String tag = (j['tag_name'] as String?) ?? '';
    if (tag.isEmpty) return null;
    final Object? rawAssets = j['assets'];
    final List<AppReleaseAsset> assets = <AppReleaseAsset>[];
    if (rawAssets is List<Object?>) {
      for (final Object? a in rawAssets) {
        if (a is! Map<String, Object?>) continue;
        final String name = (a['name'] as String?) ?? '';
        final String url = (a['browser_download_url'] as String?) ?? '';
        if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
          assets.add(AppReleaseAsset(
            name: name,
            url: url,
            sizeBytes: (a['size'] as num?)?.toInt() ?? 0,
          ));
        }
      }
    }
    return AppRelease(
      tagName: tag,
      title: (j['name'] as String?) ?? tag,
      body: (j['body'] as String?) ?? '',
      publishedAt: j['published_at'] as String?,
      assets: assets,
    );
  }

  /// 发布日期（YYYY-MM-DD，解析失败回退原文）
  String get dateText {
    final DateTime? t = DateTime.tryParse(publishedAt ?? '')?.toLocal();
    if (t == null) return publishedAt ?? '';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }
}

/// Release 附件（APK）
class AppReleaseAsset {
  const AppReleaseAsset({
    required this.name,
    required this.url,
    required this.sizeBytes,
  });

  final String name;
  final String url;
  final int sizeBytes;
}

class AppUpdateService {
  AppUpdateService._();

  /// 从 repoUrl 解析 owner/repo（AppConstants 单一来源）
  static (String, String) repoSlug() {
    final Uri u = Uri.parse(AppConstants.repoUrl);
    final List<String> seg =
        u.path.split('/').where((String s) => s.isNotEmpty).toList();
    if (seg.length >= 2) return (seg[0], seg[1]);
    return ('Ming-QWQ520', 'Ming-Music');
  }

  // ---------------------------------------------------------- 版本比对

  /// 解析版本号为数字段（v1.2.3 / 1.2.3-beta → [1,2,3]）
  static List<int> versionParts(String v) {
    final String cleaned =
        v.trim().replaceFirst(RegExp('^v', caseSensitive: false), '');
    final String core = cleaned.split(RegExp('[-+]')).first;
    return <int>[
      for (final String p in core.split('.')) int.tryParse(p.trim()) ?? 0,
    ];
  }

  /// 远端 [remote] 是否比本地 [current] 更新（逐段比较，短段补 0）
  static bool isNewer(String remote, String current) {
    final List<int> r = versionParts(remote);
    final List<int> c = versionParts(current);
    final int n = r.length > c.length ? r.length : c.length;
    for (int i = 0; i < n; i++) {
      final int rv = i < r.length ? r[i] : 0;
      final int cv = i < c.length ? c[i] : 0;
      if (rv != cv) return rv > cv;
    }
    return false;
  }

  // ---------------------------------------------------------- 网络

  /// GET JSON（直连失败自动换 gh-proxy.com 镜像，与项目详情页同通路）
  static Future<Object?> _getJson(String url) async {
    for (final String candidate in <String>[url, 'https://gh-proxy.com/$url']) {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..userAgent = 'MingMusic-App';
      try {
        final HttpClientRequest req = await client.getUrl(Uri.parse(candidate));
        req.headers.set('Accept', 'application/vnd.github+json');
        final HttpClientResponse resp =
            await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200) {
          if (identical(candidate, url)) continue; // 直连失败换镜像
          return null;
        }
        final String body = await utf8.decodeStream(resp);
        return jsonDecode(body);
      } catch (_) {
        if (identical(candidate, url)) continue;
        return null;
      } finally {
        client.close();
      }
    }
    return null;
  }

  /// 最新 release（无 release / 请求失败返回 null）
  static Future<AppRelease?> fetchLatestRelease() async {
    final (String, String) slug = repoSlug();
    final Object? data =
        await _getJson('https://api.github.com/repos/${slug.$1}/${slug.$2}'
            '/releases/latest');
    if (data is Map<String, Object?>) return AppRelease.fromJson(data);
    return null;
  }

  /// 版本更新日志（最新 [perPage] 条；失败返回空表）
  static Future<List<AppRelease>> fetchReleases({int perPage = 10}) async {
    final (String, String) slug = repoSlug();
    final Object? data =
        await _getJson('https://api.github.com/repos/${slug.$1}/${slug.$2}'
            '/releases?per_page=$perPage');
    if (data is List<Object?>) {
      final List<AppRelease> out = <AppRelease>[];
      for (final Object? item in data) {
        if (item is! Map<String, Object?>) continue;
        final AppRelease? r = AppRelease.fromJson(item);
        if (r != null) out.add(r);
      }
      return out;
    }
    return const <AppRelease>[];
  }

  // ---------------------------------------------------------- 下载与安装

  /// 按机型 ABI 挑选适配 APK（supportedAbis 顺序即优先级；
  /// 找不到带 ABI 后缀的资产时回退唯一 APK）
  static Future<AppReleaseAsset?> pickAssetForDevice(
      List<AppReleaseAsset> assets) async {
    if (assets.isEmpty) return null;
    if (assets.length == 1) return assets.first;
    List<String> abis = const <String>[];
    try {
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      abis = info.supportedAbis;
    } catch (_) {
      abis = const <String>[];
    }
    for (final String abi in abis) {
      for (final AppReleaseAsset a in assets) {
        if (a.name.toLowerCase().contains(abi.toLowerCase())) return a;
      }
      // 常见命名别名：arm64-v8a ↔ v8a；armeabi-v7a ↔ v7a
      final String? alias = switch (abi) {
        'arm64-v8a' => 'v8a',
        'armeabi-v7a' => 'v7a',
        _ => null,
      };
      if (alias != null) {
        for (final AppReleaseAsset a in assets) {
          if (a.name.toLowerCase().contains(alias)) return a;
        }
      }
    }
    return assets.first; // 兜底：第一个 APK（发布者应保证顺序）
  }

  /// 流式下载 APK 到临时目录并回报进度（0~1）；返回本地文件路径。
  /// 直连失败自动换 gh-proxy.com 镜像。
  static Future<String> downloadApk(
    AppReleaseAsset asset, {
    void Function(double progress)? onProgress,
  }) async {
    final Directory tmp = await getTemporaryDirectory();
    final Directory dir = Directory('${tmp.path}/update');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String filePath = '${dir.path}/${asset.name}';
    final File file = File(filePath);
    if (file.existsSync()) await file.delete();

    final List<String> urls = <String>[
      asset.url,
      'https://gh-proxy.com/${asset.url}',
    ];
    Object? lastError;
    for (final String url in urls) {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..userAgent = 'MingMusic-App';
      try {
        final HttpClientRequest req = await client.getUrl(Uri.parse(url));
        final HttpClientResponse resp =
            await req.close().timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          await resp.drain<Object?>();
          if (identical(url, urls.first)) continue;
          throw HttpException('HTTP ${resp.statusCode}');
        }
        final int total = resp.contentLength;
        final IOSink sink = file.openWrite();
        int received = 0;
        await for (final List<int> chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
        return filePath;
      } catch (e) {
        lastError = e;
        if (file.existsSync()) file.deleteSync();
        if (identical(url, urls.first)) continue;
        rethrow;
      } finally {
        client.close();
      }
    }
    throw StateError('APK 下载失败：$lastError');
  }

  /// 拉起系统安装器（open_filex；Android 8+ 需 REQUEST_INSTALL_PACKAGES）
  static Future<void> installApk(String filePath) async {
    await OpenFilex.open(filePath,
        type: 'application/vnd.android.package-archive');
  }
}
