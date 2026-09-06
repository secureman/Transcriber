import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../player_provider.dart';

/// Speed picker opened by long-pressing the speed chip in
/// [ChapterScrubber]. A tap on the chip still cycles through the preset
/// list for a quick nudge; this sheet is for dialing in something in
/// between, e.g. 1.35x, the same way [ThemeSheet] complements the
/// tap-to-cycle theme button.
class SpeedSheet extends ConsumerWidget {
  const SpeedSheet({super.key});

  static const _presets = [0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Playback speed',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${player.speed.toStringAsFixed(2)}×',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbColor: AppColors.primary,
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: AppColors.surfaceElevated,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: player.speed.clamp(0.5, 3.0),
                min: 0.5,
                max: 3.0,
                divisions: 50, // 0.05x steps
                onChanged: (v) =>
                    notifier.setSpeed((v * 20).round() / 20),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text('0.5×',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 11)),
                  Text('3.0×',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _presets)
                  _PresetChip(
                    value: p,
                    selected: (player.speed - p).abs() < 0.001,
                    onTap: () => notifier.setSpeed(p),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final double value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.18)
              : AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Text(
          '${value.toStringAsFixed(value == value.roundToDouble() ? 1 : 2)}×',
          style: TextStyle(
            color: selected ? AppColors.primary : AppColors.textPrimary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
