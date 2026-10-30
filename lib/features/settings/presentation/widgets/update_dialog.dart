/// 应用内更新弹窗（第十七批需求）。
///
/// 每次进入 App 请求 Releases API 后若有更新即弹出：
///  - 标题「发现新版本 vX.Y.Z」+ 当前版本说明；
///  - 「更新新增功能」：release body 以 Markdown 渲染（flutter_markdown）；
///  - 三个动作：立即更新（按机型下载适配 APK → 拉起安装器，含进度条）/
///    跳过（仅关闭，下次启动仍提示）/ 跳过此版本（不再提示当前远端 tag）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/storage/prefs_keys.dart';
import '../../services/app_update_service.dart';

/// 弹出更新弹窗。返回值无意义（仅语义化 await）。
Future<void> showUpdateDialog(
  BuildContext context, {
  required AppRelease release,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => _UpdateDialog(release: release),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.release});

  final AppRelease release;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  /// null = 空闲；非 null = 下载进度（0~1）
  double? _progress;

  String? _error;
  bool _installing = false;

  bool get _busy => _progress != null || _installing;

  Future<void> _startUpdate() async {
    setState(() => _error = null);
    try {
      final AppReleaseAsset? asset = await AppUpdateService.pickAssetForDevice(
          widget.release.assets);
      if (!mounted) return;
      if (asset == null) {
        setState(() => _error = '该版本未提供可安装的 APK 附件');
        return;
      }
      setState(() => _progress = 0.0);
      final String path = await AppUpdateService.downloadApk(
        asset,
        onProgress: (double p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _progress = null;
        _installing = true;
      });
      await AppUpdateService.installApk(path);
      if (!mounted) return;
      // open_filex 已把安装意图交给系统；弹窗回到可关闭状态
      setState(() => _installing = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _installing = false;
        _error = '$e';
      });
    }
  }

  /// 「跳过此版本」：记录远端 tag，之后启动不再提示该版本
  Future<void> _skipThisVersion() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(PrefsKeys.updaterSkippedVersion,
          widget.release.tagName);
    } catch (_) {
      // 存储失败时仅当本次「跳过」处理
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String body = widget.release.body.trim().isEmpty
        ? '本次更新未提供发布说明。'
        : widget.release.body;
    return AlertDialog(
      // 需求：全部弹出框透明度统一 50%
      backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('发现新版本',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(
            'v${AppConstants.appVersion} → ${widget.release.tagName}'
            '　${widget.release.dateText}',
            style: TextStyle(
                fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text('更新新增功能',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
            // release body 原文（Markdown）滚动渲染，超高不撑爆弹窗
            Flexible(
              child: SingleChildScrollView(
                child: MarkdownBody(
                  data: body,
                  selectable: false,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(
                        fontSize: 13, height: 1.55,
                        color: theme.colorScheme.onSurface),
                    h1: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface),
                    h2: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface),
                    h3: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface),
                    listBullet: TextStyle(
                        fontSize: 13, height: 1.5,
                        color: theme.colorScheme.onSurface),
                    code: TextStyle(
                        fontSize: 12,
                        backgroundColor: theme
                            .colorScheme.surfaceContainerHighest),
                  ),
                ),
              ),
            ),
            if (_progress != null) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _progress,
                        minHeight: 6,
                        backgroundColor: theme
                            .colorScheme.surfaceContainerHighest,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            AppConstants.brandColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${(_progress! * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 4),
              Text('正在下载适配本机的安装包…',
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
            if (_installing)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('下载完成，已拉起系统安装器…',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('更新失败：$_error',
                    style: const TextStyle(
                        fontSize: 12, color: AppConstants.brandColor)),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  // 「跳过」：仅关闭 —— 下次启动仍然提示
                  Navigator.of(context).pop();
                },
          child: const Text('跳过'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  await _skipThisVersion();
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                },
          child: const Text('跳过此版本'),
        ),
        if (!_installing)
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor),
            onPressed: _busy ? null : _startUpdate,
            child: Text(_progress != null ? '下载中…' : '立即更新'),
          ),
      ],
    );
  }
}
