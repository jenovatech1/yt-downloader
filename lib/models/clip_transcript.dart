class ClipTranscriptWord {
  const ClipTranscriptWord({
    required this.word,
    required this.startSec,
    required this.endSec,
  });

  final String word;
  final double startSec;
  final double endSec;

  Map<String, dynamic> toJson() => {
    'word': word,
    'startSec': startSec,
    'endSec': endSec,
  };
}

class ClipTranscriptCue {
  const ClipTranscriptCue({
    required this.startSec,
    required this.endSec,
    required this.text,
    this.wordTimings = const [],
  });

  final double startSec;
  final double endSec;
  final String text;
  final List<ClipTranscriptWord> wordTimings;

  Map<String, dynamic> toJson() => {
    'startSec': startSec,
    'endSec': endSec,
    'text': text,
    if (wordTimings.isNotEmpty)
      'wordTimings': wordTimings.map((w) => w.toJson()).toList(),
  };
}

/// Hasil Whisper untuk Get Clip (teks bertimestamp + cue terstruktur).
class ClipTranscript {
  const ClipTranscript({required this.stampedText, required this.cues});

  final String stampedText;
  final List<ClipTranscriptCue> cues;

  Map<String, dynamic> toJson() => {
    'text': stampedText,
    'cues': cues.map((c) => c.toJson()).toList(),
  };

  /// Hanya cue yang overlap jendela hook — payload Intent lebih kecil.
  ClipTranscript forWindows(List<(double, double)> windows) {
    if (windows.isEmpty || cues.isEmpty) return this;
    final kept = <ClipTranscriptCue>[];
    for (final c in cues) {
      for (final w in windows) {
        if (c.endSec > w.$1 && c.startSec < w.$2) {
          kept.add(c);
          break;
        }
      }
    }
    if (kept.isEmpty) return this;
    final buf = StringBuffer();
    for (final c in kept) {
      buf.writeln('[${_fmt(c.startSec)}-${_fmt(c.endSec)}] ${c.text}');
    }
    return ClipTranscript(stampedText: buf.toString().trim(), cues: kept);
  }

  static String _fmt(double sec) {
    final totalMs = (sec * 1000).round().clamp(0, 24 * 3600 * 1000);
    final h = totalMs ~/ 3600000;
    final m = (totalMs % 3600000) ~/ 60000;
    final s = (totalMs % 60000) ~/ 1000;
    final ms = totalMs % 1000;
    String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${p(h)}:${p(m)}:${p(s)}.${p(ms, 3)}';
  }
}
