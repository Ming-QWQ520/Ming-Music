/// 添加网络直链曲目弹窗（我的音乐页）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../providers/library_providers.dart';

/// 打开添加直链弹窗；成功返回 true
Future<bool> showAddNetworkSheet(BuildContext context) async {
  final bool? ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) => const _AddNetworkSheet(),
  );
  return ok ?? false;
}

class _AddNetworkSheet extends ConsumerStatefulWidget {
  const _AddNetworkSheet();

  @override
  ConsumerState<_AddNetworkSheet> createState() => _AddNetworkSheetState();
}

class _AddNetworkSheetState extends ConsumerState<_AddNetworkSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _artist = TextEditingController();
  final TextEditingController _url = TextEditingController();
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _submitting = true;
    });
    final bool ok = await ref.read(libraryProvider.notifier).addNetworkTrack(
          title: _title.text,
          artist: _artist.text,
          url: _url.text.trim(),
        );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = '请检查直链格式（需为 http/https 地址）';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '添加网络直链',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '标题',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _artist,
            decoration: const InputDecoration(
              labelText: '歌手（可选）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '音频直链 https://...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12.5,
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor,
              ),
              onPressed: _submitting ? null : _submit,
              child: Text(_submitting ? '添加中…' : '添加'),
            ),
          ),
        ],
      ),
    );
  }
}
