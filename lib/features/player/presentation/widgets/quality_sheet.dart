/// 音质选择底部弹窗（播放页进度行中央标签 / 自定义面板共用）。
/// 切换后全队列按新音质重解析直链并保留进度续播。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../settings/domain/settings_models.dart';
import '../../providers/player_providers.dart';
import '../../../../core/widgets/sheet_host.dart'
    show GlassSheet, showMingSheet;

/// 弹出音质选择
Future<void> showQualitySheet(BuildContext context, AudioQuality current) {
  return showMingSheet<void>(
    context,
    builder: (BuildContext ctx) => _QualitySheet(current: current),
  );
}

class _QualitySheet extends ConsumerStatefulWidget {
  const _QualitySheet({required this.current});

  final AudioQuality current;

  @override
  ConsumerState<_QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends ConsumerState<_QualitySheet> {
  String? _switching;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 液态玻璃弹窗底板（需求）
    return GlassSheet(
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 10),
            Text('选择音质',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface)),
            const SizedBox(height: 6),
            // 需求（songurl.txt）：音质档位扩到 10 档 —— 列表改为
            // 可滚动，避免小屏底部溢出
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final AudioQuality q in AudioQuality.values)
                      ListTile(
                        title: Text(
                          q.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: q == widget.current
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: q == widget.current
                                ? AppConstants.brandColor
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        trailing: _switching == q.name
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : (q == widget.current
                                ? const Icon(Icons.check_rounded,
                                    color: AppConstants.brandColor, size: 20)
                                : null),
                        onTap: _switching != null
                            ? null
                            : () async {
                                setState(() => _switching = q.name);
                                final String? error = await ref
                                    .read(playerProvider.notifier)
                                    .switchQuality(q);
                                if (!context.mounted) return;
                                Navigator.of(context).pop();
                                if (error != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text('切换失败：$error')));
                                }
                              },
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
