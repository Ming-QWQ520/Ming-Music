/// 一起听邀请深链服务（第二十五批需求：好友可点击链接加入）。
///
/// 链接形态：`mingmusic://listen/join?roomId=X&inviterId=Y`
/// （AndroidManifest 已在 MainActivity 注册 scheme/host intent-filter）。
///
///  - 冷启动：getInitialLink() 在首帧后取一次，直接带参进一起听页；
///  - 热启动：uriLinkStream 持续监听（App 已在前台时点击链接）；
///  - 全链路容错：app_links 异常/无链接/参数残缺全部静默，
///    绝不影响正常启动；800ms 节流防重复 push。
library;

import 'dart:async';

import 'package:app_links/app_links.dart';

import '../../../core/router.dart';
import '../../../core/utils/diag.dart';

class DeepLinkService {
  DeepLinkService._();

  static StreamSubscription<Uri>? _sub;
  static bool _initialized = false;
  static DateTime _lastHandledAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 首帧后调用（不阻塞启动，内部全容错）
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final AppLinks links = AppLinks();
      // 冷启动：链接拉起 App 时首帧后可取到 initial link
      try {
        final Uri? initial = await links.getInitialLink().timeout(
              const Duration(seconds: 3),
            );
        if (initial != null) _handle(initial, coldStart: true);
      } catch (e) {
        Diag.log('深链 initialLink 获取失败（忽略）: $e');
      }
      // 热启动：App 已在前台/后台时点击链接
      _sub = links.uriLinkStream.listen(
        (Uri uri) => _handle(uri),
        onError: (Object e) => Diag.log('深链流异常（忽略）: $e'),
      );
    } catch (e) {
      Diag.log('深链服务初始化失败（忽略）: $e');
    }
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  /// 解析并跳转：仅处理 mingmusic://listen/join?roomId=&inviterId=
  static void _handle(Uri uri, {bool coldStart = false}) {
    try {
      if (uri.scheme.toLowerCase() != 'mingmusic') return;
      final String host = uri.host.toLowerCase();
      final String path = uri.path.toLowerCase();
      // 兼容 mingmusic://listen/join 与 mingmusic://listen
      if (host != 'listen' && !path.contains('listen')) return;
      final String roomId = uri.queryParameters['roomId'] ?? '';
      final int inviterId =
          int.tryParse(uri.queryParameters['inviterId'] ?? '') ?? 0;
      if (roomId.isEmpty || inviterId <= 0) return;
      // 节流：800ms 内重复深链（系统重投/连点）只处理一次
      final DateTime now = DateTime.now();
      if (now.difference(_lastHandledAt) < const Duration(milliseconds: 800)) {
        return;
      }
      _lastHandledAt = now;
      Diag.log('深链加入一起听: room=$roomId inviter=$inviterId cold=$coldStart');
      appRouter.push<void>(
          '/listen?roomId=${Uri.encodeComponent(roomId)}&inviterId=$inviterId');
    } catch (e) {
      Diag.log('深链处理异常（忽略）: $e');
    }
  }
}
