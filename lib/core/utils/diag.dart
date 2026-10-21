/// 运行诊断：全局异常捕获 + 落盘 + release 友好错误页。
///
/// 背景：release 包出现「灰色屏幕，无法正常进入」时，Flutter 默认的
/// ErrorWidget 只渲染一块死灰色，且异常不写 logcat，用户与开发者双方
/// 都拿不到任何线索。本模块提供三层兜底：
///
///  1. [installHooks] —— FlutterError.onError / PlatformDispatcher.onError /
///     ErrorWidget.builder 三钩子全部接管：任何异步异常、构建异常都会
///     进入 [log]，构建异常渲染为 [_DiagErrorPage]（错误摘要 + 重启按钮），
///     不再是无信息的灰屏；
///  2. [log] —— 带时间戳写入内存环形缓冲，并落盘到
///     `<applicationSupport>/diag.log`（上次启动日志轮转为 diag.1.log，
///     启动时自动把上一次的日志打回 logcat —— 用户只需抓一次日志即可
///     看到上次崩溃/卡点的完整现场）；
///  3. [lastRunLog] —— 设置页「运行诊断」直接展示最近两次启动的日志，
///     无需电脑。
///
/// 全模块自容错：诊断自身故障（磁盘满/IO 异常）绝不能反过来影响业务，
/// 所有文件操作均有 try-catch。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class Diag {
  Diag._();

  static const int _maxLines = 600;

  /// 当前启动会话的日志行（内存环形）
  static final List<String> _lines = <String>[];

  /// 上一次启动会话的日志（轮转所得，可能为空）
  static String _lastRun = '';

  static File? _file;

  static final DateTime _t0 = DateTime.now();

  /// 启动时调用：轮转旧日志 → 回打 logcat → 打开新文件
  static Future<void> init() async {
    try {
      final Directory support = await getApplicationSupportDirectory();
      final File cur = File('${support.path}/diag.log');
      final File prev = File('${support.path}/diag.1.log');
      if (prev.existsSync()) prev.deleteSync();
      if (cur.existsSync()) {
        try {
          cur.renameSync(prev.path);
          _lastRun = prev.readAsStringSync();
        } catch (_) {}
      }
      _file = cur;
    } catch (e) {
      debugPrint('Diag.init failed: $e');
    }
    // 上次启动的现场回打 logcat（release 也可 adb logcat -s flutter 读取）
    if (_lastRun.isNotEmpty) {
      for (final String line in _lastRun.split('\n')) {
        debugPrint('[diag/prev] $line');
      }
    }
    log('======== 新启动会话 ========');
  }

  /// 上一会话日志（设置页展示用）
  static String get lastRunLog => _lastRun;

  /// 本会话日志全文（设置页展示用）
  static String get sessionLog => _lines.join('\n');

  /// 两次会话合并（设置页展示用）
  static String get combinedLog =>
      '===== 上次启动 =====\n$_lastRun\n===== 本次启动 =====\n${_lines.join('\n')}';

  static void log(String msg) {
    final DateTime now = DateTime.now();
    final int ts = now.difference(_t0).inMilliseconds;
    final String line =
        '${now.toIso8601String().substring(11, 23)} +${ts}ms  $msg';
    _lines.add(line);
    if (_lines.length > _maxLines) _lines.removeAt(0);
    debugPrint('[diag] $line');
    _write(line);
  }

  /// 标记启动里程碑（相对耗时一目了然）
  static void milestone(String what) {
    final int ms = DateTime.now().difference(_t0).inMilliseconds;
    log('[milestone] $what @ ${ms}ms');
  }

  static void _write(String line) {
    final File? f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // 磁盘故障等：诊断降级为仅内存，绝不影响业务
    }
  }

  /// 安装全局错误钩子（main 中 ensureInitialized 后调用）
  static void installHooks() {
    FlutterError.onError = (FlutterErrorDetails details) {
      log('FlutterError: ${details.exception}');
      log('  stack(首5帧): ${_firstFrames(details.stack, 5)}');
      // 保留框架原有的 debugPrint 行为（debug 模式仍输出全量）
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      log('Uncaught: $error');
      log('  stack(首5帧): ${_firstFrames(stack, 5)}');
      return true; // 已处理，避免引擎级崩溃
    };

    // release 灰屏的根治展示层：任何构建异常都渲染为可读的错误卡片
    ErrorWidget.builder = (FlutterErrorDetails details) {
      log('BuildError: ${details.exception}');
      return const _DiagErrorPage();
    };
  }

  static String _firstFrames(StackTrace? st, int n) {
    if (st == null) return '<null>';
    final List<String> lines =
        st.toString().split('\n').where((String l) => l.trim().isNotEmpty).toList();
    return lines.take(n).join(' | ');
  }
}

/// 构建异常的友好页面（替代 release 死灰屏）
class _DiagErrorPage extends StatelessWidget {
  const _DiagErrorPage();

  @override
  Widget build(BuildContext context) {
    // 注意：此处样式必须零依赖（不能再触发任何 provider/主题查找）
    return ColoredBox(
      color: const Color(0xFF141414),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, color: Color(0xFFE57373), size: 52),
              const SizedBox(height: 18),
              const Text(
                '页面出现了一点问题',
                style: TextStyle(color: Colors.white, fontSize: 17),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              const Text(
                '详细错误已记录在 设置 → 运行诊断',
                style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 26),
              OutlinedButton.icon(
                onPressed: () => exit(0),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重启应用'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF616161)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
