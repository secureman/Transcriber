import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echoread/core/providers/playback_progress_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('BookPlaybackProgress', () {
    test('saves and restores per-book progress', () async {
      final prefs = await SharedPreferences.getInstance();
      await BookPlaybackProgress.save(prefs, 'item-1', 3, 120.5);

      final restored = BookPlaybackProgress.fromPrefs(prefs, 'item-1');
      expect(restored, isNotNull);
      expect(restored!.chapterIndex, 3);
      expect(restored.positionSeconds, closeTo(120.5, 0.001));
      expect(restored.updatedAtEpochMs, isNotNull);
    });

    test('progress for one book never leaks into another', () async {
      final prefs = await SharedPreferences.getInstance();
      await BookPlaybackProgress.save(prefs, 'li_alpha', 1, 42.0);

      expect(BookPlaybackProgress.fromPrefs(prefs, 'li_alpha'), isNotNull);
      expect(BookPlaybackProgress.fromPrefs(prefs, 'li_beta'), isNull);
    });

    test('keeps the legacy last-played-chapter key in sync', () async {
      final prefs = await SharedPreferences.getInstance();
      await BookPlaybackProgress.save(prefs, 'item-1', 4, 12.0);

      // Book-detail "READ ALONG" continue button reads this key.
      expect(prefs.getInt('last_played_chapter_item-1'), 4);
    });

    test('overwrites the previous chapter/position on re-save', () async {
      final prefs = await SharedPreferences.getInstance();
      await BookPlaybackProgress.save(prefs, 'item-1', 0, 10.0);
      await BookPlaybackProgress.save(prefs, 'item-1', 1, 999.0);

      final restored = BookPlaybackProgress.fromPrefs(prefs, 'item-1')!;
      expect(restored.chapterIndex, 1);
      expect(restored.positionSeconds, closeTo(999.0, 0.001));
    });

    test('returns null for missing or corrupt payloads', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(BookPlaybackProgress.fromPrefs(prefs, 'missing'), isNull);

      // Not JSON.
      await prefs.setString('playback_progress_corrupt', 'not json');
      expect(BookPlaybackProgress.fromPrefs(prefs, 'corrupt'), isNull);

      // JSON but missing required fields.
      await prefs.setString('playback_progress_partial', '{"chapterIndex": 2}');
      expect(BookPlaybackProgress.fromPrefs(prefs, 'partial'), isNull);
    });
  });
}
