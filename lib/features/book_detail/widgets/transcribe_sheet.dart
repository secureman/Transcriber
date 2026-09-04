import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../book_detail_provider.dart';

class TranscribeSheet extends ConsumerStatefulWidget {
  final String itemId;
  final int totalChapters;
  final int fromChapter;

  const TranscribeSheet({
    super.key,
    required this.itemId,
    required this.totalChapters,
    required this.fromChapter,
  });

  @override
  ConsumerState<TranscribeSheet> createState() => _TranscribeSheetState();
}

class _TranscribeSheetState extends ConsumerState<TranscribeSheet> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final remaining = widget.totalChapters - widget.fromChapter;
    final options = <({String label, String detail, String mode, Duration est})>[
      (
        label: 'This chapter only',
        detail: '~30 seconds',
        mode: TranscribeMode.chapter,
        est: const Duration(seconds: 30),
      ),
      if (remaining > 1)
        (
          label: 'Next 5 chapters from here',
          detail: '~3 minutes',
          mode: TranscribeMode.next5,
          est: const Duration(minutes: 3),
        ),
      if (widget.totalChapters > 1)
        (
          label: 'Entire book (${widget.totalChapters} chapters)',
          detail: '~8 minutes',
          mode: TranscribeMode.book,
          est: const Duration(minutes: 8),
        ),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transcribe chapters',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 20),
            ...List.generate(options.length, (i) {
              final opt = options[i];
              return _OptionTile(
                selected: _selected == i,
                label: opt.label,
                detail: opt.detail,
                onTap: () => setState(() => _selected = i),
              );
            }),
            const SizedBox(height: 24),
            Consumer(
              builder: (context, ref, _) {
                final tState = ref.watch(transcribeProvider);
                return SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: tState.submitting ? null : _start,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    child: tState.submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.highlightText),
                          )
                        : const Text('START TRANSCRIPTION'),
                  ),
                );
              },
            ),
            if (ref.watch(transcribeProvider).error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  ref.watch(transcribeProvider).error!,
                  style: const TextStyle(color: AppColors.error, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _start() async {
    final modes = [TranscribeMode.chapter, TranscribeMode.next5, TranscribeMode.book];
    final mode = modes[_selected.clamp(0, modes.length - 1)];

    final ok = await ref.read(transcribeProvider.notifier).start(
          itemId: widget.itemId,
          mode: mode,
          chapterIndex: widget.fromChapter,
          totalChapters: widget.totalChapters,
        );

    if (!mounted) return;
    Navigator.of(context).pop(ok);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            ok ? 'Transcription started' : 'Failed to start transcription'),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final bool selected;
  final String label;
  final String detail;
  final VoidCallback onTap;

  const _OptionTile({
    required this.selected,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppColors.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? AppColors.primary : AppColors.textSecondary,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
