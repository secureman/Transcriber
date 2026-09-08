import 'package:flutter_test/flutter_test.dart';
import 'package:echoread/core/utils/vtt_parser.dart';

void main() {
  const sampleVtt = '''WEBVTT

00:00:01.000 --> 00:00:04.500
<00:00:01.000><c>وكان</c> <00:00:01.800><c>الجمل</c> <00:00:02.400><c>يمشي</c> <00:00:03.100><c>ببطء</c>

00:00:04.500 --> 00:00:08.000
<00:00:04.500><c>نحو</c> <00:00:05.000><c>الواحة</c> <00:00:05.900><c>البعيدة</c>

NOTE This is a comment block without timestamps

00:00:08.000 --> 00:00:12.250
<00:00:08.000><c>وفي</c> <00:00:08.700><c>أذنيه</c> <00:00:09.500><c>صوت</c> <00:00:10.200><c>الريح</c>
''';

  group('VttParser.parse', () {
    test('parses cue count correctly, skipping header and notes', () {
      final cues = VttParser.parse(sampleVtt);
      expect(cues.length, 3);
    });

    test('parses cue start/end timestamps', () {
      final cues = VttParser.parse(sampleVtt);
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 4, milliseconds: 500));
      expect(cues[2].end, const Duration(seconds: 12, milliseconds: 250));
    });

    test('parses karaoke words with per-word start times', () {
      final cues = VttParser.parse(sampleVtt);
      final words = cues[0].words;
      expect(words.length, 4);
      expect(words[0].text, 'وكان');
      expect(words[0].start, const Duration(seconds: 1));
      expect(words[1].text, 'الجمل');
      expect(words[1].start, const Duration(seconds: 1, milliseconds: 800));
      expect(words[3].start, const Duration(seconds: 3, milliseconds: 100));
    });

    test('flattenWords produces contiguous ordered refs', () {
      final cues = VttParser.parse(sampleVtt);
      final flat = VttParser.flattenWords(cues);
      expect(flat.length, 11);
      // First word: cue 0, word 0.
      expect(flat.first.cueIndex, 0);
      expect(flat.first.wordIndex, 0);
      // Word after cue 0's 4 words: cue 1, word 0.
      expect(flat[4].cueIndex, 1);
      expect(flat[4].wordIndex, 0);
      // Last word: cue 2.
      expect(flat.last.cueIndex, 2);
      expect(flat.last.text, 'الريح');
    });

    test('handles plain-text cues without karaoke tags', () {
      const plain = '''WEBVTT

00:00:02.000 --> 00:00:05.000
Hello world this is a plain cue
''';
      final cues = VttParser.parse(plain);
      expect(cues.length, 1);
      expect(cues.first.words.length, 1);
      expect(cues.first.words.first.text, 'Hello world this is a plain cue');
      expect(cues.first.words.first.start, const Duration(seconds: 2));
    });

    test('handles single-digit hours and empty content', () {
      expect(
        VttParser.parseTimestamp('1:02:03.456'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 456),
      );
      expect(VttParser.parse('WEBVTT\n\nno cues here'), isEmpty);
      expect(VttParser.parse(''), isEmpty);
    });

    test('parseTimestamp handles milliseconds shorter than 3 digits', () {
      expect(
        VttParser.parseTimestamp('00:00:01.5'),
        const Duration(seconds: 1, milliseconds: 500),
      );
    });
  });

  group('VttParser.findWordAt', () {
    test('binary search finds the active word', () {
      final cues = VttParser.parse(sampleVtt);
      final flat = VttParser.flattenWords(cues);

      // Before first word → null.
      expect(VttParser.findWordAt(const Duration(milliseconds: 500), flat),
          isNull);
      // Exactly at word 2 start (00:02.400) → word index 2.
      expect(
        VttParser.findWordAt(const Duration(seconds: 2, milliseconds: 400),
                flat)!
            .wordIndex,
        2,
      );
      // Between word 2 and word 3 → still word 2 (last start <= pos).
      expect(
        VttParser.findWordAt(const Duration(seconds: 2, milliseconds: 700),
                flat)!
            .wordIndex,
        2,
      );
      // Far into cue 2 → resolves across cues.
      expect(
        VttParser.findWordAt(const Duration(seconds: 9, milliseconds: 600),
                flat)!
            .cueIndex,
        2,
      );
      // Empty list → null.
      expect(VttParser.findWordAt(const Duration(seconds: 1), const []),
          isNull);
    });
  });
}
