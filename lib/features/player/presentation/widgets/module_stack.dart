/// 播放页模块栈：按 LayoutConfig 的 DIY 顺序渲染
/// 【封面 / 歌词 / 进度条 / 控制栏】四个模块（手机端单列）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../settings/domain/settings_models.dart';
import '../../../settings/providers/settings_providers.dart';
import 'control_bar.dart';
import 'lyrics_view.dart';
import 'progress_bar.dart';
import 'rotating_cover.dart';

class PlayerModuleStack extends ConsumerWidget {
  const PlayerModuleStack({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<PlayerModule> order =
        ref.watch(layoutProvider.select((LayoutConfig c) => c.normalized));

    return Column(
      children: <Widget>[
        for (final PlayerModule module in order)
          Expanded(
            flex: module.flex,
            child: _module(context, ref, module),
          ),
      ],
    );
  }

  Widget _module(BuildContext context, WidgetRef ref, PlayerModule module) {
    switch (module) {
      case PlayerModule.cover:
        return const RotatingCover();
      case PlayerModule.lyrics:
        return const LyricsView();
      case PlayerModule.progress:
        return const PlayerProgressBar();
      case PlayerModule.controls:
        return const PlayerControlBar();
    }
  }
}
