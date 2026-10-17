/// 播放详情底部 Sheet：
///  - 全 App 第二个（也是最后一个）允许使用液态玻璃的场景；
///  - 展示曲目信息、收藏开关、倍速选择。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/duration_utils.dart';
import '../../../../core/widgets/cover_image.dart';
import '../../../../core/widgets/liquid_glass_container.dart';
import '../../../library/domain/track.dart';
import '../../../library/providers/library_providers.dart';
import '../../providers/player_providers.dart';

Future<void> showPlayerDetailSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (BuildContext sheetContext) {
      // Consumer 包裹以便 Sheet 内部读取 Riverpod
      return const _DetailSheetBody();
    },
  );
}

class _DetailSheetBody extends ConsumerWidget {
  const _DetailSheetBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    if (track == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LiquidGlassContainer(
        borderRadius: 28,
        blurSigma: 22,
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 拖拽指示条
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.white.withValues(alpha: 0.28),
                ),
              ),
            ),
            Row(
              children: <Widget>[
                CoverImage(src: track.cover, size: 64, radius: 16),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${track.artist} · ${track.album}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _InfoRow(
              icon: Icons.album_outlined,
              label: '专辑',
              value: track.album,
            ),
            _InfoRow(
              icon: Icons.person_outline_rounded,
              label: '歌手',
              value: track.artist,
            ),
            _InfoRow(
              icon: Icons.link_rounded,
              label: '来源',
              value: track.isNetwork ? '网络直链' : '本地音频资源',
            ),
            if (track.durationMs != null)
              _InfoRow(
                icon: Icons.timer_outlined,
                label: '时长',
                value: Duration(milliseconds: track.durationMs!).clock,
              ),
            const SizedBox(height: 8),
            const _FavoriteRow(),
            const SizedBox(height: 14),
            const _SpeedRow(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- rows

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 19, color: Colors.white.withValues(alpha: 0.55)),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FavoriteRow extends ConsumerWidget {
  const _FavoriteRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track =
        ref.watch(playerProvider.select((PlayerState s) => s.currentTrack));
    final String id = track?.id ?? '';
    final bool fav = ref
        .watch(favoriteIdsProvider.select((Set<String> s) => s.contains(id)));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(Icons.favorite_outline_rounded,
              size: 19, color: Colors.white.withValues(alpha: 0.55)),
          const SizedBox(width: 12),
          const Text('收藏本曲',
              style: TextStyle(fontSize: 13.5, color: Colors.white70)),
          const Spacer(),
          Switch(
            value: fav,
            onChanged: (bool v) =>
                ref.read(favoriteIdsProvider.notifier).toggle(id),
            activeTrackColor: const Color(0xFF9D8CFF),
            thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
          ),
        ],
      ),
    );
  }
}

class _SpeedRow extends ConsumerWidget {
  const _SpeedRow();

  static const List<double> _speeds = <double>[0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double speed =
        ref.watch(playerProvider.select((PlayerState s) => s.speed));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: <Widget>[
              Icon(Icons.speed_rounded,
                  size: 19, color: Colors.white.withValues(alpha: 0.55)),
              const SizedBox(width: 12),
              Text('播放倍速',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Colors.white.withValues(alpha: 0.55),
                  )),
            ],
          ),
        ),
        Row(
          children: <Widget>[
            for (final double s in _speeds)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: GestureDetector(
                    onTap: () => ref.read(playerProvider.notifier).setSpeed(s),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: (speed == s)
                            ? Colors.white.withValues(alpha: 0.92)
                            : Colors.white.withValues(alpha: 0.10),
                      ),
                      child: Text(
                        '${s}x',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: (speed == s)
                              ? const Color(0xFF2A2440)
                              : Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
