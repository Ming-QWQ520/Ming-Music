/// 播放页自定义面板（参考 Zephyr-Music SettingsPanel）：
///
/// 需求（重构）：选择类设置项不再直接平铺所有可选按钮 —— 行内只显示
/// 「标签 + 当前值 + >」，点击弹底部选择弹窗（_PickerRow）；
/// 所有小注释字（hint）已按需求移除。
///  - 显示：布局 → Mini 播放条样式；
///  - 封面：样式 → 封面歌词 → 大小 → 投影 → MV 标识；
///  - 背景：类型 → 自定义图 → 效果（模糊 → 变暗）；
///  - 歌词：排版（字号/行距/对齐/翻译/居中）→ 效果（淡出/模糊/高亮）
///    → 逐字颜色。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/sheet_host.dart';
import '../../settings/domain/settings_models.dart';
import '../../settings/providers/settings_providers.dart';
import '../domain/np_settings.dart';
import '../providers/np_settings_providers.dart';

/// 弹出播放页自定义面板
Future<void> showNpSettingsSheet(BuildContext context) {
  return showMingSheet<void>(
    context,
    isScrollControlled: true,
    barrierLabel: '播放页自定义',
    builder: (BuildContext ctx) => const NpSettingsSheet(),
  );
}

class NpSettingsSheet extends ConsumerWidget {
  const NpSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 需求：液态玻璃弹窗底板（低端机/关闭玻璃自动降级实色）
    return DefaultTabController(
      length: 4,
      child: GlassSheet(
        borderRadius: 24,
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Row(
                children: <Widget>[
                  const Text(
                    '播放页自定义',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      ref.read(npSettingsProvider.notifier).reset();
                    },
                    child: const Text('恢复默认',
                        style:
                            TextStyle(color: Colors.white38, fontSize: 12.5)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white60, size: 22),
                  ),
                ],
              ),
            ),
            const TabBar(
              indicatorColor: AppConstants.brandColor,
              indicatorSize: TabBarIndicatorSize.label,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white38,
              tabs: <Widget>[
                Tab(text: '显示'),
                Tab(text: '封面'),
                Tab(text: '背景'),
                Tab(text: '歌词'),
              ],
            ),
            const Expanded(
              child: TabBarView(
                children: <Widget>[
                  _DisplayPane(),
                  _CoverPane(),
                  _BackgroundPane(),
                  _LyricsPane(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 显示

class _DisplayPane extends ConsumerWidget {
  const _DisplayPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    return _SettingsList(
      children: <Widget>[
        const _GroupTitle('显示模式'),
        _PickerRow<NpDisplayMode>(
          label: '布局',
          groups: const <(NpDisplayMode, String)>[
            (NpDisplayMode.both, '自适应'),
            (NpDisplayMode.cover, '仅封面'),
            (NpDisplayMode.lyrics, '仅歌词'),
          ],
          value: cfg.displayMode,
          onChanged: (NpDisplayMode v) =>
              ref.read(npSettingsProvider.notifier).setDisplayMode(v),
        ),
        const _GroupTitle('Mini 播放条'),
        _PickerRow<MiniPlayerStyle>(
          label: '样式',
          groups: const <(MiniPlayerStyle, String)>[
            (MiniPlayerStyle.classic, '经典条'),
            (MiniPlayerStyle.compact, '紧凑极简'),
          ],
          value: cfg.miniStyle,
          onChanged: (MiniPlayerStyle v) =>
              ref.read(npSettingsProvider.notifier).setMiniStyle(v),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 封面

class _CoverPane extends ConsumerWidget {
  const _CoverPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    return _SettingsList(
      children: <Widget>[
        const _GroupTitle('封面样式'),
        // 需求：封面只保留正方形/方形圆角，默认方形圆角
        _PickerRow<NpCoverStyle>(
          label: '样式',
          groups: const <(NpCoverStyle, String)>[
            (NpCoverStyle.square, '正方形'),
            (NpCoverStyle.rounded, '方形圆角'),
          ],
          value: cfg.coverStyle,
          onChanged: (NpCoverStyle v) =>
              ref.read(npSettingsProvider.notifier).setCoverStyle(v),
        ),
        _PickerRow<NpCoverLyricsMode>(
          label: '封面歌词',
          groups: const <(NpCoverLyricsMode, String)>[
            (NpCoverLyricsMode.none, '关闭'),
            (NpCoverLyricsMode.one, '一行'),
            (NpCoverLyricsMode.two, '两行'),
          ],
          value: cfg.coverLyrics,
          onChanged: (NpCoverLyricsMode v) =>
              ref.read(npSettingsProvider.notifier).setCoverLyrics(v),
        ),
        _SliderRow(
          label: '封面大小',
          value: (cfg.coverScale - 0.7) / 0.5,
          display: '${(cfg.coverScale * 100).round()}%',
          onChanged: (double v) => ref
              .read(npSettingsProvider.notifier)
              .setCoverScale(0.7 + v * 0.5),
        ),
        _SwitchRow(
          label: '封面投影',
          value: cfg.coverShadow,
          onChanged: (bool v) =>
              ref.read(npSettingsProvider.notifier).setCoverShadow(v),
        ),
        // 需求：UI 排列优化 —— MV 标识是歌名旁徽标，归入本页末尾而非夹在封面属性中
        _SwitchRow(
          label: 'MV 标识',
          value: cfg.showMvBadge,
          onChanged: (bool v) =>
              ref.read(npSettingsProvider.notifier).setShowMvBadge(v),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 背景

class _BackgroundPane extends ConsumerWidget {
  const _BackgroundPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    final BackgroundConfig bg = ref.watch(backgroundProvider);
    return _SettingsList(
      children: <Widget>[
        const _GroupTitle('背景类型'),
        _PickerRow<BackgroundType>(
          label: '类型',
          groups: const <(BackgroundType, String)>[
            (BackgroundType.blurCover, '封面模糊'),
            (BackgroundType.fluid, '流体'),
            (BackgroundType.image, '自定义图'),
          ],
          value: bg.type,
          onChanged: (BackgroundType v) =>
              ref.read(backgroundProvider.notifier).setType(v),
        ),
        if (bg.type == BackgroundType.image)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 14),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('自定义背景图',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.86),
                          fontSize: 14)),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(backgroundProvider.notifier).pickImage(),
                  child: const Text('选择图片'),
                ),
                if (bg.imagePath != null)
                  TextButton(
                    onPressed: () =>
                        ref.read(backgroundProvider.notifier).clearImage(),
                    child: const Text('清除'),
                  ),
              ],
            ),
          ),
        const _GroupTitle('背景效果'),
        _SliderRow(
          label: '模糊强度',
          value: (cfg.bgBlur - 4) / 36,
          display: '${cfg.bgBlur.round()}px',
          onChanged: (double v) =>
              ref.read(npSettingsProvider.notifier).setBgBlur(4 + v * 36),
        ),
        _SliderRow(
          label: '变暗程度',
          value: cfg.bgDim / 100,
          display: '${cfg.bgDim.round()}%',
          onChanged: (double v) =>
              ref.read(npSettingsProvider.notifier).setBgDim(v * 100),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 歌词

class _LyricsPane extends ConsumerWidget {
  const _LyricsPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NpPlayerSettings cfg = ref.watch(npSettingsProvider);
    return _SettingsList(
      children: <Widget>[
        const _GroupTitle('排版'),
        _SliderRow(
          label: '字号',
          value: (cfg.lyricFontSize - 12) / 28,
          display: '${cfg.lyricFontSize.round()}px',
          onChanged: (double v) => ref
              .read(npSettingsProvider.notifier)
              .setLyricFontSize(12 + v * 28),
        ),
        _SliderRow(
          label: '行间距',
          value: (cfg.lyricLineGap - 8) / 40,
          display: '${cfg.lyricLineGap.round()}px',
          onChanged: (double v) =>
              ref.read(npSettingsProvider.notifier).setLyricLineGap(8 + v * 40),
        ),
        _PickerRow<NpLyricAlign>(
          label: '对齐',
          groups: const <(NpLyricAlign, String)>[
            (NpLyricAlign.left, '左对齐'),
            (NpLyricAlign.center, '居中'),
          ],
          value: cfg.lyricAlign,
          onChanged: (NpLyricAlign v) =>
              ref.read(npSettingsProvider.notifier).setLyricAlign(v),
        ),
        _SwitchRow(
          label: '显示翻译副行',
          value: cfg.showTranslation,
          onChanged: (bool v) =>
              ref.read(npSettingsProvider.notifier).setShowTranslation(v),
        ),
        _SwitchRow(
          label: '时刻保持居中',
          value: cfg.lyricAlwaysCenter,
          onChanged: (bool v) =>
              ref.read(npSettingsProvider.notifier).setLyricAlwaysCenter(v),
        ),
        const _GroupTitle('效果'),
        _SliderRow(
          label: '非活跃行淡出',
          value: cfg.lyricFade,
          display: '${(cfg.lyricFade * 100).round()}%',
          onChanged: (double v) =>
              ref.read(npSettingsProvider.notifier).setLyricFade(v),
        ),
        _SliderRow(
          label: '非活跃行模糊',
          value: cfg.lyricBlur / 3,
          display: '${cfg.lyricBlur.toStringAsFixed(1)}px',
          onChanged: (double v) =>
              ref.read(npSettingsProvider.notifier).setLyricBlur(v * 3),
        ),
        _SwitchRow(
          label: '高亮已播放歌词',
          value: cfg.highlightPlayed,
          onChanged: (bool v) =>
              ref.read(npSettingsProvider.notifier).setHighlightPlayed(v),
        ),
        const _GroupTitle('逐字颜色'),
        _ColorRow(
          label: '已唱颜色',
          value: cfg.yrcPlayed,
          onChanged: (Color c) => ref
              .read(npSettingsProvider.notifier)
              .setYrcColors(c, cfg.yrcUnplayed),
        ),
        _ColorRow(
          label: '未唱颜色',
          value: cfg.yrcUnplayed,
          onChanged: (Color c) => ref
              .read(npSettingsProvider.notifier)
              .setYrcColors(cfg.yrcPlayed, c),
        ),
        // 第十五批需求：红心动效已移除（原「动效」组仅此一项，整组删除）
      ],
    );
  }
}

// ---------------------------------------------------------------- 通用行

class _SettingsList extends StatelessWidget {
  const _SettingsList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
      children: children,
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.38),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// 需求（重构）：选择类设置项不再直接平铺所有可选按钮 ——
/// 行内只显示「标签 + 当前值 + >」，点击弹出底部选择弹窗（统一玻璃底）。
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.groups,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<(T, String)> groups;
  final T value;
  final ValueChanged<T> onChanged;

  String get _currentText {
    for (final (T, String) g in groups) {
      if (g.$1 == value) return g.$2;
    }
    return groups.isEmpty ? '' : groups.first.$2;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _pick(context),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.86),
                        fontSize: 14),
                  ),
                ),
                Text(
                  _currentText,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 13),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: Colors.white.withValues(alpha: 0.35)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _pick(BuildContext context) {
    showMingSheet<void>(
      context,
      barrierLabel: '选择$label',
      builder: (BuildContext ctx) => GlassSheet(
        borderRadius: 24,
        maxHeight: MediaQuery.sizeOf(ctx).height * 0.55,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选择$label',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                children: <Widget>[
                  for (final (T, String) g in groups)
                    ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      title: Text(
                        g.$2,
                        style: TextStyle(
                          color: g.$1 == value
                              ? AppConstants.brandColor
                              : Colors.white.withValues(alpha: 0.88),
                          fontWeight:
                              g.$1 == value ? FontWeight.w700 : FontWeight.w400,
                          fontSize: 14.5,
                        ),
                      ),
                      trailing: g.$1 == value
                          ? const Icon(Icons.check_rounded,
                              color: AppConstants.brandColor, size: 20)
                          : null,
                      onTap: () {
                        onChanged(g.$1);
                        Navigator.of(ctx).pop();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.86), fontSize: 14),
            ),
          ),
          Switch.adaptive(
            value: value,
            activeThumbColor: AppConstants.brandColor,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.86), fontSize: 14),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: value.clamp(0.0, 1.0),
                activeColor: AppConstants.brandColor,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Color value;
  final ValueChanged<Color> onChanged;

  static const List<Color> _presets = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFFFA233B),
    Color(0xFFFFC53D),
    Color(0xFF4ADE80),
    Color(0xFF38BDF8),
    Color(0xFFB388FF),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.86), fontSize: 14),
            ),
          ),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              children: <Widget>[
                for (final Color c in _presets)
                  GestureDetector(
                    onTap: () => onChanged(c),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: value == c ? Colors.white : Colors.white24,
                          width: value == c ? 2.4 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
