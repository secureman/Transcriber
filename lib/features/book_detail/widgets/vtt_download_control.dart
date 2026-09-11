import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/vtt_download_provider.dart';
import '../../../core/theme/app_theme.dart';

/// "Download transcripts" control for the book detail screen: bulk-caches
/// every `done` chapter's VTT so read-along keeps working when the
/// transcription backend is unreachable (playback itself always continues
/// via ABS). Sits directly under [DownloadControl].
class VttDownloadControl extends ConsumerWidget {
  final String itemId;

  const VttDownloadControl({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vttDownloadProvider(itemId));

    if (state.isRunning) {
      return _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.totalCount > 0
                        ? 'Caching transcripts… '
                            '${state.doneCount + state.alreadyCached} '
                            'of ${state.totalCount}'
                        : 'Fetching transcript list…',
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return FilledButton.tonalIcon(
      onPressed: () async {
        final ok =
            await ref.read(vttDownloadProvider(itemId).notifier).start(itemId);
        if (!context.mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        final s = ref.read(vttDownloadProvider(itemId));
        if (ok) {
          final parts = <String>[
            if (s.doneCount > 0) '${s.doneCount} downloaded',
            if (s.alreadyCached > 0) '${s.alreadyCached} already on device',
          ];
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                parts.isEmpty
                    ? 'Transcripts cached — read-along works offline'
                    : 'Transcripts saved (${parts.join(', ')}) — '
                        'read-along works offline',
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppColors.surfaceElevated,
            ),
          );
        } else {
          messenger.showSnackBar(
            SnackBar(
              content: Text(s.error ?? 'Could not download transcripts'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppColors.surfaceElevated,
            ),
          );
        }
      },
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      icon: const Icon(Icons.subtitles_outlined),
      label: const Text('Download transcripts'),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: child,
    );
  }
}
