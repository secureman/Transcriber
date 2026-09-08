extension DurationFormat on Duration {
  /// "3:24" or "1:02:05" for scrubber labels.
  String get mmss {
    final h = inHours;
    final m = inMinutes.remainder(60);
    final s = inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// "2h 14m" style for book detail headers.
  String get humanReadable {
    final h = inHours;
    final m = inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m';
    return '${inSeconds}s';
  }
}

/// Audiobookshelf-style time-remaining adjustment: audio time remaining
/// divided by the playback speed (10 minutes of audio at 2× = 5 minutes
/// of listening left). Falls back to the unadjusted [remaining] when
/// [speed] isn't usable (0, negative, or absurdly small).
Duration atPlaybackSpeed(Duration remaining, double speed) {
  if (speed <= 0.05) return remaining;
  return Duration(milliseconds: (remaining.inMilliseconds / speed).round());
}

extension DoubleSeconds on double {
  Duration get asDuration => Duration(milliseconds: (this * 1000).round());
}
