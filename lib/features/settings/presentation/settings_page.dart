/// 设置页：主题 / 背景系统 / 液态玻璃 / 播放音质 / 关于。
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
    final ThemeData theme = Theme.of(context);
    final ThemeMode mode = ref.watch(themeModeProvider);
    final GlassPref glass = ref.watch(glassPrefProvider);
    final bool glassEnabled = ref.watch(glassEnabledProvider);
    final BackgroundConfig bg = ref.watch(backgroundProvider);
    final AudioQuality quality = ref.watch(audioQualityProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          '设置',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          _GroupCard(
            title: '外观',
            children: <Widget>[
              _RadioRow<ThemeMode>(
                label: '主题模式',
                groups: const <(ThemeMode, String)>[
                  (ThemeMode.system, '跟随系统'),
                  (ThemeMode.light, '浅色'),
                  (ThemeMode.dark, '深色'),
                ],
                value: mode,
                onChanged: (ThemeMode v) =>
                    ref.read(themeModeProvider.notifier).set(v),
              ),
              _RadioRow<GlassPref>(
                label: '液态玻璃（Mini 播放条）',
                subtitle: glassEnabled ? '当前设备已启用' : '当前设备性能不足，已自动降级为纯半透明',
                groups: const <(GlassPref, String)>[
                  (GlassPref.auto, '自动'),
                  (GlassPref.on, '开启'),
                  (GlassPref.off, '关闭'),
                ],
                value: glass,
                onChanged: (GlassPref v) =>
                    ref.read(glassPrefProvider.notifier).set(v),
              ),
              _RadioRow<BackgroundType>(
                label: '播放页背景',
                groups: const <(BackgroundType, String)>[
                  (BackgroundType.blurCover, '封面模糊'),
                  (BackgroundType.gradient, '纯色渐变'),
                  (BackgroundType.image, '自定义图片'),
                ],
                value: bg.type,
                onChanged: (BackgroundType v) =>
                    ref.read(backgroundProvider.notifier).setType(v),
              ),
              if (bg.type == BackgroundType.gradient)
                _GradientPicker(
                  selectedIndex: bg.gradientIndex,
                  onSelected: (int i) =>
                      ref.read(backgroundProvider.notifier).setGradientIndex(i),
                ),
              if (bg.type == BackgroundType.image)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              ref.read(backgroundProvider.notifier).pickImage(),
                          icon: const Icon(Icons.image_rounded, size: 18),
                          label: const Text('选择图片'),
                        ),
                      ),
                      if (bg.imagePath != null) ...<Widget>[
                        const SizedBox(width: 10),
                        TextButton(
                          onPressed: () => ref
                              .read(backgroundProvider.notifier)
                              .clearImage(),
                          child: const Text('恢复默认'),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),

          const SizedBox(height: 16),

          // ---------------- 播放 ----------------
          _GroupCard(
            title: '播放',
            children: <Widget>[
              _RadioRow<AudioQuality>(
                label: '播放音质',
                subtitle: '无损音质需要网易 VIP，游客通常回落到标准',
                groups: const <(AudioQuality, String)>[
                  (AudioQuality.standard, '标准'),
                  (AudioQuality.higher, '较高'),
                  (AudioQuality.exhigh, '极高'),
                  (AudioQuality.lossless, '无损'),
                ],
                value: quality,
                onChanged: (AudioQuality v) =>
                    ref.read(audioQualityProvider.notifier).set(v),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---------------- 数据源 ----------------
          _GroupCard(
            title: '数据源',
            children: <Widget>[
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                title: const Text('网易云音乐 API'),
                subtitle: const Text(AppConstants.apiBaseUrl),
                trailing: Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Text(
                  '数据来自第三方公开 API，VIP 专属歌曲在未登录状态下仅可试听或不可播放；'
                  '本应用仅供学习交流，请支持正版音乐。',
                  style: TextStyle(fontSize: 12.5, height: 1.5),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---------------- 关于 ----------------
          _GroupCard(
            title: '关于',
            children: <Widget>[
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                title: const Text(AppConstants.appName),
                subtitle: const Text('版本 ${AppConstants.appVersion}'),
              ),
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                title: const Text('项目仓库'),
                subtitle: const Text(AppConstants.repoUrl),
                trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 组件

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white60,
            ),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _RadioRow<T extends Object> extends StatelessWidget {
  const _RadioRow({
    required this.label,
    required this.groups,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final List<(T, String)> groups;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 15)),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final (T, String) g in groups)
                _ChoiceChip<T>(
                  label: g.$2,
                  selected: g.$1 == value,
                  onTap: () => onChanged(g.$1),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChoiceChip<T extends Object> extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (bool _) => onTap(),
      labelStyle: TextStyle(
        fontSize: 13,
        color: selected
            ? Colors.white
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      selectedColor: AppConstants.brandColor,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _GradientPicker extends StatelessWidget {
  const _GradientPicker({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: kGradientPresets.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (BuildContext context, int index) {
            final GradientPreset p = kGradientPresets[index];
            final bool selected = index == selectedIndex;
            return GestureDetector(
              onTap: () => onSelected(index),
              child: Container(
                width: 74,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(
                    colors: <Color>[p.top, p.bottom],
                  ),
                  border: selected
                      ? Border.all(color: Colors.white, width: 2)
                      : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  p.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
