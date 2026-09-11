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
  final Set<int> _pickedChapters = {};

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
      (
        label: 'Choose chapters…',
        detail: _pickedChapters.isEmpty
            ? 'Pick exactly which chapters to transcribe'
            : '${_pickedChapters.length} chapter'
                '${_pickedChapters.length == 1 ? '' : 's'} selected',
        mode: TranscribeMode.custom,
        est: const Duration(seconds: 0),
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
                onTap: () async {
                  setState(() => _selected = i);
                  if (opt.mode == TranscribeMode.custom) {
                    await _openPicker();
                    if (mounted) setState(() {}); // refresh the count label
                  }
                },
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

  /// Opens the multi-select chapter picker and merges its result into
  /// [_pickedChapters]. Nothing selected → the option stays but START is
  /// blocked with a hint (see _start).
  Future<void> _openPicker() async {
    final picked = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ChapterPickerSheet(
        itemId: widget.itemId,
        totalChapters: widget.totalChapters,
        initial: Set<int>.of(_pickedChapters),
      ),
    );
    if (picked != null) {
      _pickedChapters
        ..clear()
        ..addAll(picked);
    }
  }

  Future<void> _start() async {
    final modes = [
      TranscribeMode.chapter,
      TranscribeMode.next5,
      TranscribeMode.book,
      TranscribeMode.custom,
    ];
    final mode = modes[_selected.clamp(0, modes.length - 1)];

    if (mode == TranscribeMode.custom) {
      if (_pickedChapters.isEmpty) {
        await _openPicker();
        if (!mounted) return;
        if (_pickedChapters.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Select at least one chapter first'),
          ));
          return;
        }
      }
    }

    final ok = await ref.read(transcribeProvider.notifier).start(
          itemId: widget.itemId,
          mode: mode,
          chapterIndex: widget.fromChapter,
          totalChapters: widget.totalChapters,
          chapterIndices: _pickedChapters.toList(),
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

/// Multi-select chapter list shown as a bottom sheet when the user picks
/// "Choose chapters…". Returns the selected chapter indices via
/// `Navigator.pop(context, <int>{...})`, or null if dismissed.
class _ChapterPickerSheet extends ConsumerStatefulWidget {
  final String itemId;
  final int totalChapters;
  final Set<int> initial;

  const _ChapterPickerSheet({
    required this.itemId,
    required this.totalChapters,
    required this.initial,
  });

  @override
  ConsumerState<_ChapterPickerSheet> createState() =>
      _ChapterPickerSheetState();
}

class _ChapterPickerSheetState extends ConsumerState<_ChapterPickerSheet> {
  late final Set<int> _selected = Set<int>.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    final meta = ref.watch(bookDetailProvider(widget.itemId)).valueOrNull;
    final chapters = meta?.chapters ?? const [];
    final allSelected =
        chapters.isNotEmpty && _selected.length == chapters.length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
              children: [
                Expanded(
                  child: Text(
                    _selected.isEmpty
                        ? 'Select chapters'
                        : '${_selected.length} chapter'
                            '${_selected.length == 1 ? '' : 's'} selected',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: chapters.isEmpty
                      ? null
                      : () => setState(() {
                            if (allSelected) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(
                                    List.generate(chapters.length, (i) => i));
                            }
                          }),
                  child: Text(allSelected ? 'None' : 'All'),
                ),
              ],
            ),
            if (chapters.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Chapter list unavailable',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapters.length,
                  itemBuilder: (context, i) {
                    final checked = _selected.contains(i);
                    return InkWell(
                      onTap: () => setState(() {
                        checked ? _selected.remove(i) : _selected.add(i);
                      }),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: checked,
                                onChanged: (v) => setState(() {
                                  v == true
                                      ? _selected.add(i)
                                      : _selected.remove(i);
                                }),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${i + 1}. ${chapters[i].title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 14.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () =>
                        Navigator.of(context).pop(Set<int>.of(_selected)),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: Text(_selected.isEmpty
                    ? 'SELECT CHAPTERS'
                    : 'TRANSCRIBE ${_selected.length} CHAPTER'
                        '${_selected.length == 1 ? '' : 'S'}'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
