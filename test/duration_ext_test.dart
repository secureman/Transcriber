import 'package:flutter_test/flutter_test.dart';
import 'package:ereader/core/utils/duration_ext.dart';

void main() {
  group('atPlaybackSpeed (ABS-style time-remaining adjustment)', () {
    test('divides remaining audio time by the playback speed', () {
      // 10 minutes of audio at 2× = 5 minutes of listening left.
      expect(
        atPlaybackSpeed(const Duration(minutes: 10), 2.0),
        const Duration(minutes: 5),
      );
      // 60 minutes at 1.5× = 40 minutes.
      expect(
        atPlaybackSpeed(const Duration(minutes: 60), 1.5),
        const Duration(minutes: 40),
      );
      // 1h 30m at 0.75× = 2h.
      expect(
        atPlaybackSpeed(const Duration(hours: 1, minutes: 30), 0.75),
        const Duration(hours: 2),
      );
    });

    test('is identity at 1×', () {
      const d = Duration(hours: 3, minutes: 7, seconds: 13);
      expect(atPlaybackSpeed(d, 1.0), d);
    });

    test('falls back to unadjusted time for unusable speeds', () {
      const d = Duration(minutes: 10);
      expect(atPlaybackSpeed(d, 0.0), d);
      expect(atPlaybackSpeed(d, -2.0), d);
      // Below the 0.05 guard the division would explode the duration.
      expect(atPlaybackSpeed(d, 0.01), d);
    });

    test('rounds to the nearest millisecond instead of truncating', () {
      // 1000ms / 3 = 333.33ms → rounds to 333ms (truncation would give 333
      // here, but 2ms/3 = 0.67 → 1ms proves rounding).
      expect(atPlaybackSpeed(const Duration(milliseconds: 2), 3.0),
          const Duration(milliseconds: 1));
    });
  });

  group('DurationFormat.humanReadable (used by the "Xh Ym left" labels)', () {
    test('formats hours and minutes', () {
      expect(const Duration(hours: 2, minutes: 14).humanReadable, '2h 14m');
    });
    test('formats sub-hour durations', () {
      expect(const Duration(minutes: 48).humanReadable, '48m');
    });
    test('formats sub-minute durations', () {
      expect(const Duration(seconds: 42).humanReadable, '42s');
    });
    test('drops trailing minutes', () {
      expect(const Duration(hours: 3).humanReadable, '3h 0m');
    });
  });
}
