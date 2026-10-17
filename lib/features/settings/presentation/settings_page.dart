/// 设置页：
///  - 主题模式；
///  - 背景系统（模糊封面 / 渐变预设 / 本地图片）；
///  - 液态玻璃降级开关（避坑指南 2 的用户侧出口）；
///  - 播放页模块 DIY 拖拽排序（序列化保存）；
///  - 关于。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../domain/settings_models.dart';
import '../providers/settings_providers.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar.large(title: const Text('设置')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          sliver: SliverList.list(
            children: <Widget>[
              const _SectionCard(
                title: '外观',
                child: _ThemeModeSection(),
              ),
              const _SectionCard(
                title: '播放页背景',
                child: _BackgroundSection(),
              ),
              const _SectionCard(
                title: '液态玻璃',
                child: _GlassSection(),
              ),
              const _SectionCard(
                title: '播放页模块排序',
                child: _LayoutSection(),
              ),
              const _SectionCard(
                title: '关于',
                child: _AboutSection(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 容器

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 主题

class _ThemeModeSection extends ConsumerWidget {
  const _ThemeModeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(themeModeProvider);
    return SegmentedButton<ThemeMode>(
      segments: const <ButtonSegment<ThemeMode>>[
        ButtonSegment<ThemeMode>(
            value: ThemeMode.system,
            label: Text('跟随系统'),
            icon: Icon(Icons.brightness_auto_rounded)),
        ButtonSegment<ThemeMode>(
            value: ThemeMode.light,
            label: Text('浅色'),
            icon: Icon(Icons.light_mode_outlined)),
        ButtonSegment<ThemeMode>(
            value: ThemeMode.dark,
            label: Text('深色'),
            icon: Icon(Icons.dark_mode_outlined)),
      ],
      selected: <ThemeMode>{mode},
      onSelectionChanged: (Set<ThemeMode> s) =>
          ref.read(themeModeProvider.notifier).set(s.first),
    );
  }
}

// ---------------------------------------------------------------- 背景

class _BackgroundSection extends ConsumerWidget {
  const _BackgroundSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BackgroundConfig config = ref.watch(backgroundProvider);
    final BackgroundNotifier notifier = ref.read(backgroundProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final (int i, BackgroundType type)
                in BackgroundType.values.indexed)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == 2 ? 0 : 8),
                  child: _BackgroundTypeChip(
                    selected: config.type == type,
                    icon: switch (type) {
                      BackgroundType.blurCover => Icons.blur_on_rounded,
                      BackgroundType.gradient => Icons.gradient_rounded,
                      BackgroundType.image => Icons.wallpaper_rounded,
                    },
                    label: switch (type) {
                      BackgroundType.blurCover => '模糊封面',
                      BackgroundType.gradient => '纯色渐变',
                      BackgroundType.image => '本地图片',
                    },
                    onTap: () => notifier.setType(type),
                  ),
                ),
              ),
          ],
        ),
        // 渐变预设选择器
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: config.type == BackgroundType.gradient
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    children: <Widget>[
                      for (final (int i, GradientPreset p)
                          in kGradientPresets.indexed)
                        Expanded(
                          child: GestureDetector(
                            onTap: () => notifier.setGradientIndex(i),
                            child: Container(
                              height: 44,
                              margin: EdgeInsets.only(
                                  right:
                                      i == kGradientPresets.length - 1 ? 0 : 8),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[p.top, p.bottom],
                                ),
                                border: config.gradientIndex == i
                                    ? Border.all(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        width: 2.4,
                                      )
                                    : null,
                              ),
                              child: Text(
                                p.name,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  shadows: <Shadow>[
                                    Shadow(
                                        color: Colors.black54, blurRadius: 4),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
        // 本地图片操作
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: config.type == BackgroundType.image
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: () => notifier.pickImage(),
                        icon:
                            const Icon(Icons.photo_library_outlined, size: 18),
                        label: const Text('选择图片'),
                      ),
                      if (config.imagePath != null) ...<Widget>[
                        const SizedBox(width: 10),
                        TextButton.icon(
                          onPressed: () => notifier.clearImage(),
                          icon: const Icon(Icons.delete_outline_rounded,
                              size: 18),
                          label: const Text('移除'),
                        ),
                      ],
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _BackgroundTypeChip extends StatelessWidget {
  const _BackgroundTypeChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: selected
              ? scheme.primaryContainer
              : scheme.onSurface.withValues(alpha: 0.05),
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon,
                size: 18,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurface.withValues(alpha: 0.6)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- glass

class _GlassSection extends ConsumerWidget {
  const _GlassSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GlassPref pref = ref.watch(glassPrefProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SegmentedButton<GlassPref>(
          segments: const <ButtonSegment<GlassPref>>[
            ButtonSegment<GlassPref>(
                value: GlassPref.auto,
                label: Text('自动'),
                icon: Icon(Icons.auto_mode_rounded)),
            ButtonSegment<GlassPref>(
                value: GlassPref.on,
                label: Text('开启'),
                icon: Icon(Icons.blur_on_rounded)),
            ButtonSegment<GlassPref>(
                value: GlassPref.off,
                label: Text('关闭'),
                icon: Icon(Icons.blur_off_rounded)),
          ],
          selected: <GlassPref>{pref},
          onSelectionChanged: (Set<GlassPref> s) =>
              ref.read(glassPrefProvider.notifier).set(s.first),
        ),
        const SizedBox(height: 10),
        Text(
          '「自动」模式下：Android 12 及以上启用真实 BackdropFilter 模糊，'
          '更低版本自动降级为纯半透明背景，避免 GPU 高负载掉帧。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- layout

class _LayoutSection extends ConsumerWidget {
  const _LayoutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<PlayerModule> modules =
        ref.watch(layoutProvider.select((LayoutConfig c) => c.normalized));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: true,
          itemCount: modules.length,
          // Flutter 3.41+ 新 API：newIndex 已自动修正，无需手动减 1
          onReorderItem: (int oldIndex, int newIndex) =>
              ref.read(layoutProvider.notifier).reorder(oldIndex, newIndex),
          itemBuilder: (BuildContext context, int index) {
            final PlayerModule m = modules[index];
            return ListTile(
              key: ValueKey<PlayerModule>(m),
              leading: Icon(
                switch (m) {
                  PlayerModule.cover => Icons.album_rounded,
                  PlayerModule.lyrics => Icons.lyrics_outlined,
                  PlayerModule.progress => Icons.av_timer_rounded,
                  PlayerModule.controls => Icons.touch_app_rounded,
                },
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(m.label, style: const TextStyle(fontSize: 14.5)),
              subtitle: Text(
                index == 0 ? '最上方' : '第 ${index + 1} 位',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Text(
                '拖动排序',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.4),
                ),
              ),
            );
          },
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => ref.read(layoutProvider.notifier).reset(),
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('恢复默认顺序'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- about

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0xFF8B7CF6), Color(0xFF5B2FD1)],
                ),
              ),
              child: const Icon(Icons.music_note_rounded,
                  color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  AppConstants.appName,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  'v${AppConstants.appVersion} · Flutter 液态玻璃音乐播放器',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          '音频引擎 just_audio + audio_service · 状态管理 Riverpod · '
          'Material Design 3 · 液态玻璃局部渲染',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.6,
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}
