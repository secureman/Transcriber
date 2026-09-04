class VttWord {
  final String text;
  final Duration start;

  const VttWord({required this.text, required this.start});
}

class VttCue {
  final Duration start;
  final Duration end;
  final List<VttWord> words;

  const VttCue({required this.start, required this.end, required this.words});
}

/// Reference to a word with its position in the flat word list.
class VttWordRef {
  final int cueIndex;
  final int wordIndex;
  final VttWord word;

  const VttWordRef({
    required this.cueIndex,
    required this.wordIndex,
    required this.word,
  });

  Duration get start => word.start;

  String get text => word.text;
}
