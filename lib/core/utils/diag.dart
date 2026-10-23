/// 运行诊断：全局异常捕获 + 落盘（内部 + 外部镜像）+ release 友好错误页。
///
/// 背景：release 包出现「灰色屏幕/页面异常，无法正常进入」时，Flutter 默认的
/// ErrorWidget 只渲染一块死灰色，且异常不写 logcat，用户与开发者双方
/// 都拿不到任何线索。本模块提供四层兜底：
///
///  1. [installHooks] —— FlutterError.onError / PlatformDispatcher.onError /
///     ErrorWidget.builder 三钩子全部接管：任何异步异常、构建异常都会
///     进入 [log]，构建异常渲染为 [_DiagErrorPage]（错误摘要 + 复制 +
///     重启），不再是无信息的灰屏；
///  2. [log] —— 带时间戳写入内存环形缓冲，双路落盘：
///     内部 `<applicationSupport>/diag.log`（上次启动轮转为 diag.1.log，
///     启动时自动把上一次的日志打回 logcat）+ **外部镜像**
///     `Android/data/com.ming.music/files/diag.log` —— HarmonyOS 3.0
///     （Android 10 底层）的系统文件管理器可直接浏览该目录，用户无需
///     ADB 即可取走日志；
///  3. [lastNativeCrash] —— 收录原生侧全局兜底捕获（MainActivity 写入
///     同目录 native_crash.log，本模块读取后删除）的崩溃记录，Dart 钩子
///     看不到的 Java/Kotlin 崩溃从此也有据可查；
///  4. [lastRunLog] —— 设置页「运行诊断」直接展示最近两次启动日志 +
///     上次原生崩溃，无需电脑。
///
/// 全模块自容错：诊断自身故障（磁盘满/IO 异常）绝不能反过来影响业务，
/// 所有文件操作均有 try-catch。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class Diag {
  Diag._();

  static const int _maxLines = 600;

  /// 当前启动会话的日志行（内存环形）
  static final List<String> _lines = <String>[];

  /// 上一次启动会话的日志（轮转所得，可能为空）
  static String _lastRun = '';

  /// 上一次启动的原生崩溃记录（MainActivity 兜底捕获，读取后删除）
  static String _lastNativeCrash = '';

  /// 内部日志文件（应用沙盒，仅 debug/诊断页可读）
  static File? _file;

  /// 外部镜像日志文件（`Android/data/<pkg>/files/`，文件管理器可读）
  static File? _mirrorFile;

  static final DateTime _t0 = DateTime.now();

  /// 启动时调用：轮转旧日志 → 回打 logcat → 打开新文件（内部 + 外部镜像）
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
    // 外部镜像：用户在系统文件管理器 → Android/data/com.ming.music/files/
    // 可直接查看 diag.log / diag.1.log / device_info.txt（无需 ADB）。
    try {
      final Directory? ext = await getExternalStorageDirectory();
      if (ext != null) {
        if (!ext.existsSync()) ext.createSync(recursive: true);
        final File cur = File('${ext.path}/diag.log');
        final File prev = File('${ext.path}/diag.1.log');
        if (prev.existsSync()) prev.deleteSync();
        if (cur.existsSync()) {
          try {
            cur.renameSync(prev.path);
          } catch (_) {}
        }
        _mirrorFile = cur;
        // 收录上次启动的原生崩溃记录（MainActivity 全局兜底捕获写入）
        final File crash = File('${ext.path}/native_crash.log');
        if (crash.existsSync()) {
          try {
            _lastNativeCrash = crash.readAsStringSync();
            crash.deleteSync();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('Diag.init external mirror failed: $e');
    }
    // 上次启动的现场回打 logcat（release 也可 adb logcat -s flutter 读取）
    if (_lastRun.isNotEmpty) {
      for (final String line in _lastRun.split('\n')) {
        debugPrint('[diag/prev] $line');
      }
    }
    log('======== 新启动会话 ========');
    if (_lastNativeCrash.isNotEmpty) {
      log('检测到上次启动的原生崩溃记录，已收录诊断页（native_crash.log）');
    }
  }

  /// 上一会话日志（设置页展示用）
  static String get lastRunLog => _lastRun;

  /// 上一次启动的原生崩溃记录（可能为空）
  static String get lastNativeCrash => _lastNativeCrash;

  /// 本会话日志全文（设置页展示用）
  static String get sessionLog => _lines.join('\n');

  /// 三段合并（设置页展示用）：上次启动 + 上次原生崩溃 + 本次启动
  static String get combinedLog =>
      '===== 上次启动 =====\n$_lastRun\n'
      '===== 上次原生崩溃（如有） =====\n'
      '${_lastNativeCrash.isEmpty ? '（无）' : _lastNativeCrash}\n'
      '===== 本次启动 =====\n${_lines.join('\n')}';

  /// 复制到剪贴板的完整诊断包：设备信息 + 三段日志
  static String get reportForCopy =>
      'device: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
      '$combinedLog\n'
      'mirrorDir: ${_mirrorFile?.path ?? '<不可用>'}';

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
    if (f != null) {
      try {
        f.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
      } catch (_) {
        // 磁盘故障等：诊断降级为仅内存，绝不影响业务
      }
    }
    final File? m = _mirrorFile;
    if (m != null) {
      try {
        m.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
      } catch (_) {
        // 外部镜像失败不影响内部日志
      }
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

    // release 灰屏的根治展示层：任何构建异常都渲染为可读的错误卡片，
    // 并直接展示错误摘要（用户截图/复制即可反馈，无需 ADB）
    ErrorWidget.builder = (FlutterErrorDetails details) {
      log('BuildError: ${details.exception}');
      return _DiagErrorPage(details.exception.toString());
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
///
/// v2：直接展示错误摘要 + 一键复制完整诊断包（设备信息 + 两次启动日志 +
/// 上次原生崩溃），用户截图/复制即可获得精确故障现场。
class _DiagErrorPage extends StatelessWidget {
  const _DiagErrorPage(this.summary);

  /// 触发本次错误页的异常摘要（超长截断）
  final String summary;

  @override
  Widget build(BuildContext context) {
    // 注意：此处样式必须零依赖（不能再触发任何 provider/主题查找）
    final String short = summary.length > 1200
        ? '${summary.substring(0, 1200)}\n…（已截断，完整内容可复制诊断包查看）'
        : summary;
    return ColoredBox(
      color: const Color(0xFF141414),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Icon(Icons.error_outline, color: Color(0xFFE57373), size: 48),
                const SizedBox(height: 16),
                const Text(
                  '页面出现了一点问题',
                  // inherit:false —— 错误页可能被注入在 MaterialApp 之上
                  // （无 DefaultTextStyle，引擎 fallback 带黄色下划线），
                  // 必须彻底脱离环境样式才能保证可读性
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    inherit: false,
                    decoration: TextDecoration.none,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  '请截图本页或点击「复制诊断信息」反馈给开发者',
                  style: TextStyle(
                    color: Color(0xFF9E9E9E),
                    fontSize: 12.5,
                    inherit: false,
                    decoration: TextDecoration.none,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF333333)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      short,
                      style: const TextStyle(
                        color: Color(0xFFCFCFCF),
                        fontSize: 11.5,
                        height: 1.45,
                        inherit: false,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await Clipboard.setData(
                        ClipboardData(text: 'MingMusic 诊断\n$summary\n${Diag.reportForCopy}'),
                      );
                    } catch (_) {}
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('复制诊断信息'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF616161)),
                  ),
                ),
                const SizedBox(height: 10),
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
      ),
    );
  }
}
