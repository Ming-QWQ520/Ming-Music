/// 运行诊断日志查看页（设置 → 关于 → 运行诊断）。
///
/// 展示上次启动 + 本次启动的诊断日志（启动里程碑 / 全局异常 /
/// 构建异常摘要），支持复制到剪贴板。release 下出现灰屏/白屏等问题时，
/// 用户无需连接电脑即可把关键现场反馈给开发者。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/diag.dart';

class DiagPage extends StatefulWidget {
  const DiagPage({super.key});

  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  late Future<String> _future;

  @override
  void initState() {
    super.initState();
    _future = Future<String>.value(Diag.combinedLog);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行诊断'),
        actions: <Widget>[
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () async {
              final String text = await _future;
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('诊断日志已复制')),
              );
            },
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: () {
              setState(() {
                _future = Future<String>.value('（已清空展示，文件将随下次启动重置）');
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<String> snap) {
          final String text = (snap.data == null || snap.data!.isEmpty)
              ? '（暂无日志）'
              : snap.data!;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          );
        },
      ),
    );
  }
}
