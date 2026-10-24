/// 播放页自定义面板（参考 Zephyr-Music SettingsPanel；
/// 需求：UI 排列优化 —— 每页按「主属性 → 派生属性 → 开关」从上到下排列，
/// 同类属性聚合为一组，说明文案统一 _HintText 风格）：
///  - 显示：显示模式（布局）→ Mini 播放条（样式）；
///  - 封面：样式 → 封面歌词 → 大小 → 投影 → MV 标识（徽标归尾）；
///  - 背景：类型 → 自定义图 → 效果（模糊 → 变暗）；
///  - 歌词：排版（字号/行距/对齐/翻译/居中）→ 效果（淡出/模糊/高亮）
///    → 逐字颜色 → 动效（红心动效）。
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
        _SegmentedRow<NpDisplayMode>(
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
        const _HintText('自适应：平板双列分栏，手机支持封面/歌词切换'),
        const _GroupTitle('Mini 播放条'),
        _SegmentedRow<MiniPlayerStyle>(
          label: '样式',
          hint: '两种样式均带液态玻璃；紧凑极简嵌入底部导航栏中间',
          groups: const <(MiniPlayerStyle, String)>[
            (MiniPlayerStyle.classic, '经典条'),
            (MiniPlayerStyle.compact, '紧凑极简'),
          ],
          value: cfg.miniStyle,
          onChanged: (MiniPlayerStyle v) =>
              ref.read(npSettingsProvider.notifier).setMiniStyle(v),
        ),
        const _HintText(
            '经典条：高透明液态玻璃长条悬浮导航栏上方；底板颜色/透明度在「设置 → Mini 播放条」中自定义'),
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
        _SegmentedRow<NpCoverStyle>(
          label: '样式',
          groups: const <(NpCoverStyle, String)>[
            (NpCoverStyle.square, '正方形'),
            (NpCoverStyle.rounded, '方形圆角'),
          ],
          value: cfg.coverStyle,
          onChanged: (NpCoverStyle v) =>
              ref.read(npSettingsProvider.notifier).setCoverStyle(v),
        ),
        _SegmentedRow<NpCoverLyricsMode>(
          label: '封面歌词',
          hint: '借鉴 kgka_Music_hl：封面下方显示当前行歌词预览',
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
          hint: '歌名旁显示 MV 胶囊入口（点击播放 MV）',
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
        _SegmentedRow<BackgroundType>(
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
          hint: '仅封面模糊背景生效（需求默认 25px）',
          value: (cfg.bgBlur - 4) / 36,
          display: '${cfg.bgBlur.round()}px',
          onChanged: (double v) =>
              ref.read(npSettingsProvider.notifier).setBgBlur(4 + v * 36),
        ),
        _SliderRow(
          label: '变暗程度',
          hint: '封面模糊 / 流体 / 自定义图背景统一生效',
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
        _SegmentedRow<NpLyricAlign>(
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
          hint: '当前行始终位于可视区中部，歌曲开头/结尾不贴边；拖动浏览不受影响，松手后恢复跟随',
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
          value: cfg.lyricBlur / 10,
          display: '${cfg.lyricBlur.round()}px',
          onChanged: (double v) =>
              ref.read(npSettingsProvider.notifier).setLyricBlur(v * 10),
        ),
        _SwitchRow(
          label: '高亮已播放歌词',
          hint: '关：只高亮当前播放行/字；开：已唱部分保持高亮（经典卡拉OK）',
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
        const _GroupTitle('动效'),
        _SwitchRow(
          label: '红心动效',
          hint: '点击喜欢时播放心形迸发动画',
          value: cfg.heartEffect,
          onChanged: (bool v) =>
              ref.read(npSettingsProvider.notifier).setHeartEffect(v),
        ),
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

class _HintText extends StatelessWidget {
  const _HintText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.30),
          fontSize: 11.5,
        ),
      ),
    );
  }
}

class _SegmentedRow<T> extends StatelessWidget {
  const _SegmentedRow({
    required this.label,
    required this.groups,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final List<(T, String)> groups;
  final T value;
  final ValueChanged<T> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.86),
                      fontSize: 14),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.30),
                        fontSize: 11.5),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (T, String) g in groups)
                  _SegmentButton(
                    label: g.$2,
                    active: value == g.$1,
                    onTap: () => onChanged(g.$1),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? AppConstants.brandColor
          : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6.5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              color: active ? Colors.white : Colors.white70,
            ),
          ),
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
    this.hint,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.86),
                      fontSize: 14),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.30),
                        fontSize: 11.5),
                  ),
              ],
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
    this.hint,
  });

  final String label;
  final double value;
  final String display;
  final ValueChanged<double> onChanged;

  /// 可选说明（需求：UI 排列优化 —— 滑杆的作用对象紧跟说明）
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final Widget row = Row(
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
    );
    if (hint == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: row,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          row,
          Padding(
            padding: const EdgeInsets.only(left: 110, top: 2),
            child: Text(
              hint!,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.36), fontSize: 11),
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
