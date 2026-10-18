/// 设置页（kgka_Music_hl 风格分组重构）：
///
/// 分组（需求：重构设置项，进行合理分类）：
///  - 账号：个人主页 / 登录状态 / 退出登录；
///  - 外观：主题模式 / 液态玻璃 / 播放页背景；
///  - 播放：播放音质 / 播放页自定义 / MV 标识开关（默认开启）；
///  - Mini 播放条：样式选择（紧凑极简嵌入导航栏，其余悬浮上方）；
///  - 缓存：封面缓存占用与清理；
///  - 数据源 / 关于（仓库链接真实可点，需求：补全无实际作用功能）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/platform_actions.dart';
import '../../../core/widgets/cover_image.dart';
import '../../auth/providers/auth_providers.dart';
import '../../player/domain/np_settings.dart';
import '../../player/presentation/np_settings_sheet.dart';
import '../../player/providers/np_settings_providers.dart';
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
    final AuthState auth = ref.watch(authProvider);
    final NpPlayerSettings np = ref.watch(npSettingsProvider);

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
          // ---------------- 账号 ----------------
          _GroupCard(
            title: '账号',
            children: <Widget>[
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                leading: const Icon(Icons.person_rounded, size: 22),
                title: Text(
                  auth.loggedIn
                      ? (auth.profile?.nickname ?? '网易云用户')
                      : '未登录',
                  style: const TextStyle(fontSize: 15),
                ),
                subtitle: Text(
                  auth.loggedIn
                      ? '查看个人主页（VIP / 等级 / 听歌数据 / 签到）'
                      : '登录后可使用喜欢、歌单、云盘',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                onTap: () => context.push('/profile'),
              ),
              if (auth.loggedIn)
                ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: Icon(Icons.logout_rounded,
                      size: 21,
                      color: AppConstants.brandColor.withValues(alpha: 0.9)),
                  title: Text('退出登录',
                      style: TextStyle(
                          fontSize: 15,
                          color: AppConstants.brandColor
                              .withValues(alpha: 0.95))),
                  subtitle: Text('退出当前网易云音乐账号',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)),
                  onTap: () => _confirmLogout(context, ref),
                ),
            ],
          ),

          const SizedBox(height: 16),

          // ---------------- 外观 ----------------
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
                subtitle: glassEnabled
                    ? '当前设备已启用'
                    : '当前设备性能不足，已自动降级为纯半透明',
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
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                leading: const Icon(Icons.tune_rounded, size: 22),
                title: const Text('播放页自定义', style: TextStyle(fontSize: 15)),
                subtitle: Text(
                    '显示模式 / 封面 / 背景 / 歌词 / 红心动效',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant)),
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                onTap: () => showNpSettingsSheet(context),
              ),
              SwitchListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                secondary: const Icon(Icons.movie_outlined, size: 22),
                title: const Text('MV 标识', style: TextStyle(fontSize: 15)),
                subtitle: Text('歌曲名旁显示 MV 入口（默认开启）',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant)),
                value: np.showMvBadge,
                activeThumbColor: AppConstants.brandColor,
                onChanged: (bool v) =>
                    ref.read(npSettingsProvider.notifier).setShowMvBadge(v),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---------------- Mini 播放条 ----------------
          _GroupCard(
            title: 'Mini 播放条',
            children: <Widget>[
              _RadioRow<MiniPlayerStyle>(
                label: '样式',
                subtitle: '紧凑极简嵌入底部导航栏中间；其余样式悬浮导航栏上方',
                groups: const <(MiniPlayerStyle, String)>[
                  (MiniPlayerStyle.classic, '经典条'),
                  (MiniPlayerStyle.overlay, '封面铺满'),
                  (MiniPlayerStyle.compact, '紧凑极简'),
                  (MiniPlayerStyle.wide, '宽幅双行'),
                ],
                value: np.miniStyle,
                onChanged: (MiniPlayerStyle v) =>
                    ref.read(npSettingsProvider.notifier).setMiniStyle(v),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---------------- 缓存 ----------------
          const _CacheGroup(),

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
                // 需求：补全无实际作用功能 —— 仓库入口真实打开浏览器
                onTap: () async {
                  final bool ok = await PlatformActions.openUrl(
                      AppConstants.repoUrl);
                  if (!context.mounted) return;
                  if (!ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('无法打开浏览器')),
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定退出当前网易云音乐账号吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(authProvider.notifier).logout();
    }
  }
}
// ---------------------------------------------------------------- 缓存组

class _CacheGroup extends ConsumerStatefulWidget {
  const _CacheGroup();

  @override
  ConsumerState<_CacheGroup> createState() => _CacheGroupState();
}

class _CacheGroupState extends ConsumerState<_CacheGroup> {
  String _sizeText = '计算中…';

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final int bytes = await CoverImage.cacheSizeBytes();
    if (!mounted) return;
    setState(() => _sizeText = _fmt(bytes));
  }

  static String _fmt(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return _GroupCard(
      title: '缓存',
      children: <Widget>[
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: const Icon(Icons.image_outlined, size: 22),
          title: const Text('封面缓存', style: TextStyle(fontSize: 15)),
          subtitle: Text(_sizeText,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          trailing: const Icon(Icons.delete_outline_rounded, size: 20),
          onTap: () async {
            await CoverImage.clearCache();
            _refreshSize();
            if (!mounted) return;
            ScaffoldMessenger.of(this.context)
                .showSnackBar(const SnackBar(content: Text('封面缓存已清理')));
          },
        ),
      ],
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
