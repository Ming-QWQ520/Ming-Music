/// 封面全屏查看器（需求：长按音乐封面可全屏查看 + 底部按键保存至本地）：
///  - 黑底沉浸式展示原图（双指缩放 / 拖动，InteractiveViewer）；
///  - 底部「保存至本地」：下载原图字节 → 平台通道写入系统相册
///    （API 29+ MediaStore Pictures/MingMusic，API ≤28 公共目录 + 扫描）；
///  - 旧版本运行时存储权限由 permission_handler 在保存前申请。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/widgets/cover_image.dart';

import '../../../../core/widgets/app_notify.dart';
const MethodChannel _mediaChannel = MethodChannel('com.ming.music/media');

/// 打开封面全屏查看器
Future<void> showCoverViewer(
  BuildContext context, {
  required String? cover,
  String title = '',
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (BuildContext context, Animation<double> animation,
              Animation<double> secondaryAnimation) =>
          CoverViewerPage(cover: cover, title: title),
      transitionsBuilder: (BuildContext context, Animation<double> animation,
              Animation<double> secondaryAnimation, Widget child) =>
          FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
      opaque: false,
    ),
  );
}

class CoverViewerPage extends StatefulWidget {
  const CoverViewerPage({super.key, required this.cover, required this.title});

  final String? cover;
  final String title;

  @override
  State<CoverViewerPage> createState() => _CoverViewerPageState();
}

class _CoverViewerPageState extends State<CoverViewerPage> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Uint8List? bytes = await CoverImage.loadOriginalBytes(widget.cover);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_bytes == null || _saving) return;
    // Android ≤28 写公共目录需要存储权限；
    // Android 10+ 走 MediaStore 无需权限，不要误请求（13+ 必被拒）。
    if (Platform.isAndroid) {
      final RegExpMatch? m =
          RegExp(r'SDK (\d+)').firstMatch(Platform.operatingSystemVersion);
      final int? sdk = m == null ? null : int.tryParse(m.group(1)!);
      if (sdk != null && sdk < 29) {
        final PermissionStatus status = await Permission.storage.request();
        if (!status.isGranted && mounted) {
          AppNotify.show('存储权限被拒绝，无法保存');
          return;
        }
      }
    }
    setState(() => _saving = true);
    try {
      final String mime = CoverImage.sniffMime(_bytes!);
      final String ext = switch (mime) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/gif' => 'gif',
        _ => 'webp',
      };
      final String name =
          'MingMusic_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final bool? ok = await _mediaChannel.invokeMethod<bool>(
        'saveImage',
        <String, Object>{'bytes': _bytes!, 'name': name, 'mime': mime},
      );
      if (!mounted) return;
      AppNotify.show(ok == true ? '已保存到相册 Pictures/MingMusic' : '保存失败');
    } catch (e) {
      if (mounted) {
        AppNotify.show('保存失败：$e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white70),
                    ),
                  )
                : InteractiveViewer(
                    maxScale: 4,
                    child: Center(
                      child: _bytes != null
                          ? Image.memory(_bytes!, fit: BoxFit.contain)
                          : CoverImage(
                              src: widget.cover,
                              size: 280,
                              radius: 0,
                              coverSize: CoverSize.large,
                            ),
                    ),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.14),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onPressed: _bytes == null || _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white70),
                        )
                      : const Icon(Icons.save_alt_rounded, size: 20),
                  label: const Text('保存至本地',
                      style: TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
