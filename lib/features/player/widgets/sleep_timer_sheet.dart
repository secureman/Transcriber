import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../player_provider.dart';
import '../player_state.dart';

class SleepTimerSheet extends ConsumerWidget {
  const SleepTimerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Sleep timer',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          ...[
            (SleepTimerState.off, 'Off'),
            (SleepTimerState.min30, '30 minutes'),
            (SleepTimerState.min60, '60 minutes'),
            (SleepTimerState.endOfChapter, 'End of chapter'),
          ].map((e) => ListTile(
                title: Text(e.$2,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 14)),
                trailing: player.sleepTimer == e.$1
                    ? const Icon(Icons.check, color: AppColors.primary)
                    : null,
                onTap: () {
                  notifier.setSleepTimer(e.$1);
                  Navigator.of(context).pop();
                },
              )),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Shared helper so the control bar's sleep icon and the overflow menu open
/// the exact same sheet.
void showSleepTimerSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const SleepTimerSheet(),
  );
}
