import '../../models/vtt_cue.dart';

class VttParser {
  static final _timestampRegex = RegExp(
    r'(\d{1,2}:\d{2}:\d{2}\.\d{3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}\.\d{3})',
  );
  static final _wordRegex = RegExp(r'<(\d{1,2}:\d{2}:\d{2}\.\d{3})><c>([^<]*)</c>');

  /// Parses WebVTT karaoke content into a list of cues with per-word timings.
  static List<VttCue> parse(String vttContent) {
    final cues = <VttCue>[];
    // Normalize line endings, then split into raw cue blocks.
    final normalized = vttContent.replaceAll('\r\n', '\n');
    final blocks = normalized.split('\n\n');

    for (final block in blocks) {
      final lines = block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;

      // Find the line containing the timing arrow.
      final timingLineIndex =
          lines.indexWhere((l) => l.contains('-->'));
      if (timingLineIndex == -1) continue; // header / NOTE / STYLE blocks

      final match = _timestampRegex.firstMatch(lines[timingLineIndex]);
      if (match == null) continue;

      final start = parseTimestamp(match.group(1)!);
      final end = parseTimestamp(match.group(2)!);

      // Body: everything after the timing line, joined back together.
      final body = lines.skip(timingLineIndex + 1).join(' ');

      final words = <VttWord>[];
      for (final w in _wordRegex.allMatches(body)) {
        final text = w.group(2)!.trim();
        if (text.isEmpty) continue;
        words.add(VttWord(text: text, start: parseTimestamp(w.group(1)!)));
      }

      // Fallback: plain-text cue body without karaoke tags → whole body
      // becomes one word spanning the cue (better than showing nothing).
      if (words.isEmpty && body.isNotEmpty) {
        final plain = body.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        if (plain.isNotEmpty) {
          words.add(VttWord(text: plain, start: start));
        }
      }

      if (words.isNotEmpty) {
        cues.add(VttCue(start: start, end: end, words: words));
      }
    }
    return cues;
  }

  /// Flattens cues into an ordered list of word references for binary search.
  static List<VttWordRef> flattenWords(List<VttCue> cues) {
    final refs = <VttWordRef>[];
    for (var ci = 0; ci < cues.length; ci++) {
      final cue = cues[ci];
      for (var wi = 0; wi < cue.words.length; wi++) {
        refs.add(VttWordRef(cueIndex: ci, wordIndex: wi, word: cue.words[wi]));
      }
    }
    return refs;
  }

  /// Binary search: finds the last word whose start <= [pos].
  /// Returns null if [pos] is before the first word or the list is empty.
  static VttWordRef? findWordAt(Duration pos, List<VttWordRef> words) {
    if (words.isEmpty || pos < words.first.start) return null;
    int lo = 0, hi = words.length - 1, result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (words[mid].start <= pos) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result >= 0 ? words[result] : null;
  }

  /// Parses "HH:MM:SS.mmm" (or "H:MM:SS.mmm") into a [Duration].
  static Duration parseTimestamp(String ts) {
    final parts = ts.split(':');
    final secParts = parts[2].split('.');
    return Duration(
      hours: int.parse(parts[0]),
      minutes: int.parse(parts[1]),
      seconds: int.parse(secParts[0]),
      milliseconds: int.parse(secParts[1].padRight(3, '0').substring(0, 3)),
    );
  }
}
