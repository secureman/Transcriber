import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../../../models/abs_item.dart';
import '../book_detail_provider.dart';

class ChapterListTile extends StatelessWidget {
  final AbsChapter chapter;
  final int index;
  final ChapterJobStatus? job; // null → not transcribed
  final VoidCallback onTap;

  const ChapterListTile({
    super.key,
    required this.chapter,
    required this.index,
    required this.job,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onTap: onTap,
      title: Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusBadge(job: job),
            if (job?.isProcessing == true) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (job?.progressFraction ?? 0).clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: AppColors.surfaceElevated,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${(job?.progress ?? 0).clamp(0, 100).round()}%',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
      trailing: Text(
        chapter.duration.asDuration.mmss,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final ChapterJobStatus? job;

  const _StatusBadge({required this.job});

  @override
  Widget build(BuildContext context) {
    final status = job?.status;
    switch (status) {
      case ChapterJobStatus.done:
        return _pill(
          '✓ Ready',
          foreground: AppColors.success,
          background: AppColors.success.withValues(alpha: 0.12),
        );
      case ChapterJobStatus.processing:
        return _ShimmerPill(text: '⋯ Transcribing');
      case ChapterJobStatus.pending:
        return _pill(
          '⋯ Queued',
          foreground: AppColors.warning,
          background: AppColors.warning.withValues(alpha: 0.12),
        );
      case ChapterJobStatus.error:
        return Tooltip(
          message: job?.errorMessage ?? 'Transcription failed',
          child: _pill(
            '⚠ Failed',
            foreground: AppColors.error,
            background: AppColors.error.withValues(alpha: 0.12),
          ),
        );
      default:
        return _pill(
          '○ Not transcribed',
          foreground: AppColors.textSecondary,
          background: AppColors.surfaceElevated,
        );
    }
  }

  Widget _pill(String text,
      {required Color foreground, required Color background}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ShimmerPill extends StatefulWidget {
  final String text;

  const _ShimmerPill({required this.text});

  @override
  State<_ShimmerPill> createState() => _ShimmerPillState();
}

class _ShimmerPillState extends State<_ShimmerPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_controller),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          widget.text,
          style: const TextStyle(
            color: AppColors.warning,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
