import 'dart:math' as math;

/// Mirror desktop `src/lib/groq-models.ts` + `clip-plan-shards.ts` (Agu 2026).
/// Free Groq chat: 8K TPM per model — jangan spam failover payload sama.
class ClipPlanBudget {
  ClipPlanBudget._();

  static const maxRequestTokens = 5200;
  static const maxOutputTokens = 2048;
  static const promptOverheadTokens = 1400;
  static const charsPerToken = 3.2;

  static int get transcriptTokenBudget =>
      maxRequestTokens - maxOutputTokens - promptOverheadTokens;

  static int get maxTranscriptChars =>
      (transcriptTokenBudget * charsPerToken).floor();

  static int estimateTokens(String text) =>
      math.max(1, (text.length / charsPerToken).ceil());

  static String trimTranscript(String transcript, {int? maxChars}) {
    final limit = maxChars ?? maxTranscriptChars;
    final text = transcript.trim();
    if (text.length <= limit) return text;
    final section = limit ~/ 3;
    final midStart = math.max(0, text.length ~/ 2 - section ~/ 2);
    return '${text.substring(0, section)}\n--- BAGIAN TENGAH ---\n'
        '${text.substring(midStart, midStart + section)}\n'
        '--- BAGIAN AKHIR ---\n${text.substring(text.length - section)}';
  }
}

class ClipPlanShard {
  const ClipPlanShard({
    required this.text,
    required this.model,
    required this.minClips,
    required this.maxClips,
    required this.index,
  });

  final String text;
  final String model;
  final int minClips;
  final int maxClips;
  final int index;
}

/// Pecah transkrip ber-timestamp per baris agar tiap shard muat TPM budget.
List<String> splitTranscriptForTpm(
  String transcript, {
  int? tokenBudget,
}) {
  final budget = tokenBudget ?? ClipPlanBudget.transcriptTokenBudget;
  final text = transcript.trim();
  if (text.isEmpty) return const [];
  if (ClipPlanBudget.estimateTokens(text) <= budget) return [text];

  final lines = text
      .split(RegExp(r'\n+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length <= 1) {
    final maxChars = (budget * ClipPlanBudget.charsPerToken).floor();
    final parts = <String>[];
    for (var i = 0; i < text.length; i += maxChars) {
      parts.add(text.substring(i, math.min(i + maxChars, text.length)));
    }
    return parts;
  }

  final shards = <String>[];
  var buf = <String>[];
  var bufTok = 0;
  for (final line in lines) {
    final lineTok = ClipPlanBudget.estimateTokens(line);
    if (buf.isNotEmpty && bufTok + lineTok > budget) {
      shards.add(buf.join('\n'));
      buf = [];
      bufTok = 0;
    }
    if (lineTok > budget) {
      if (buf.isNotEmpty) {
        shards.add(buf.join('\n'));
        buf = [];
        bufTok = 0;
      }
      final maxChars =
          math.max(500, (budget * ClipPlanBudget.charsPerToken).floor());
      for (var i = 0; i < line.length; i += maxChars) {
        shards.add(line.substring(i, math.min(i + maxChars, line.length)));
      }
      continue;
    }
    buf.add(line);
    bufTok += lineTok;
  }
  if (buf.isNotEmpty) shards.add(buf.join('\n'));
  if (shards.isEmpty) {
    return [text.substring(0, math.min(text.length, ClipPlanBudget.maxTranscriptChars))];
  }
  return shards;
}

List<({int min, int max})> distributeClipCounts(
  int shardCount,
  int minClips,
  int maxClips,
) {
  final n = math.max(1, shardCount);
  final totalMax = math.max(1, maxClips);
  final totalMin = math.max(1, math.min(minClips, totalMax));
  var baseMax = totalMax ~/ n;
  var remMax = totalMax - baseMax * n;
  var baseMin = totalMin ~/ n;
  var remMin = totalMin - baseMin * n;
  final out = <({int min, int max})>[];
  for (var i = 0; i < n; i++) {
    var max = math.max(1, baseMax + (remMax > 0 ? 1 : 0));
    if (remMax > 0) remMax -= 1;
    var min = math.max(1, math.min(max, baseMin + (remMin > 0 ? 1 : 0)));
    if (remMin > 0) remMin -= 1;
    if (n > 1) {
      max = math.min(max, 8);
      min = math.min(min, max);
    }
    out.add((min: min, max: max));
  }
  return out;
}

/// Shard 0 → preferred, 1 → next model, … (round-robin). Bukan failover spam.
List<ClipPlanShard> buildClipPlanShards(
  String transcript, {
  required List<String> modelChain,
  String? preferredModel,
  int minClips = 8,
  int maxClips = 15,
}) {
  final preferred = (preferredModel ?? '').trim().isEmpty
      ? modelChain.first
      : preferredModel!.trim();
  final chain = <String>[
    preferred,
    ...modelChain.where((m) => m != preferred),
  ];
  final pieces = splitTranscriptForTpm(transcript);
  final counts = distributeClipCounts(
    pieces.length,
    math.max(1, minClips),
    math.max(minClips, maxClips),
  );
  return [
    for (var i = 0; i < pieces.length; i++)
      ClipPlanShard(
        text: pieces[i],
        model: chain[i % chain.length],
        minClips: counts[i].min,
        maxClips: counts[i].max,
        index: i,
      ),
  ];
}
