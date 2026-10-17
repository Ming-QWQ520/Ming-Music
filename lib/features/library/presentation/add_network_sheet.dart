/// 添加网络直链曲目（底部弹层表单）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/library_providers.dart';

Future<void> showAddNetworkSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => const _AddNetworkSheet(),
  );
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
  bool _submitting = false;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final bool ok = await ref.read(libraryProvider.notifier).addNetworkTrack(
          title: _title.text,
          artist: _artist.text,
          url: _url.text.trim(),
        );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加到音乐库')),
      );
    } else {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的 http(s) 直链')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('添加网络曲目',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('支持 mp3 / m4a / flac / aac 等浏览器可播直链',
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5),
              )),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '标题',
              prefixIcon: Icon(Icons.music_note_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _artist,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '歌手（可选）',
              prefixIcon: Icon(Icons.person_outline_rounded),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: '音频直链 URL',
              prefixIcon: Icon(Icons.link_rounded),
              border: OutlineInputBorder(),
              hintText: 'https://example.com/song.mp3',
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: const Text('添加'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}
