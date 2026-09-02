import '../config/get_clip_config.dart';
import '../models/clip_transcript.dart';
import 'clip_ai_service.dart';

class OwnAiClipSuggestion {
  const OwnAiClipSuggestion({
    required this.startTime,
    required this.endTime,
    required this.hookText,
    this.score = 70,
    this.keywords = const [],
  });

  final String startTime;
  final String endTime;
  final String hookText;
  final double score;
  final List<String> keywords;
}

class OwnAiParseResult {
  const OwnAiParseResult.ok(this.clips) : error = null, ok = true;
  const OwnAiParseResult.err(this.error) : clips = const [], ok = false;

  final bool ok;
  final List<OwnAiClipSuggestion> clips;
  final String? error;
}

String secondsToTimestamp(double sec) {
  final s = sec < 0 ? 0.0 : sec;
  final h = s ~/ 3600;
  final m = ((s % 3600) ~/ 60);
  final rest = (s % 60).toStringAsFixed(3).padLeft(6, '0');
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(h)}:${p(m)}:$rest';
}

String formatTimedTranscript(List<ClipTranscriptCue> segments) {
  final buf = StringBuffer();
  for (final seg in segments) {
    if (seg.text.trim().isEmpty) continue;
    buf.writeln(
      '[${secondsToTimestamp(seg.startSec)}-${secondsToTimestamp(seg.endSec)}] '
      '${seg.text.trim()}',
    );
  }
  return buf.toString().trim();
}

String ownAiExportFileName(String? title) {
  final safe = (title ?? 'video')
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '-')
      .toLowerCase();
  final slug = safe.isEmpty ? 'video' : safe;
  return 'klippod-clip-ai-${slug.length > 40 ? slug.substring(0, 40) : slug}.txt';
}

String buildOwnAiExportFile({
  required String transcript,
  String? clipCountRange,
  String? extraPrompt,
  String? videoTitle,
  int? durationSeconds,
}) {
  final extra = extraPrompt?.trim() ?? '';
  final durationMin = durationSeconds != null && durationSeconds > 0
      ? 'Video duration is about ${(durationSeconds / 60).round()} minutes.'
      : 'Video duration is unknown.';
  final titleLine = videoTitle?.trim().isNotEmpty == true
      ? 'Video: ${videoTitle!.trim()}\n'
      : '';

  return '''KLIPPOD IMPORT TASK — MACHINE OUTPUT ONLY
==========================================
$titleLine$durationMin

STOP. You are not a strategist. You are not writing a briefing.
You are filling a JSON import for software named KlipPod.
If you write any sentence, heading, numbered list, emoji, or markdown, the import FAILS.

Your ENTIRE reply must be exactly one JSON object.
- First character: {
- Last character: }
- No ```json
- No intro, no outro, no "here are the clips"

CLIP RULES
- Each clip MUST be ${GetClipConfig.minClipSec}–${GetClipConfig.maxClipSec} seconds.
- Return up to ${GetClipConfig.maxClips} clips if there are enough strong moments.
- Copy start_time and end_time from transcript timestamps. Do not invent times.
- Use HH:MM:SS.mmm (example 00:10:50.000).
- hook_text: 4–10 words, punchy. This becomes the visible clip title.
- score: 1–100, highest first (not chronological).
- No overlapping clips. Spread across the video.
- keywords: 1–4 short words.
${extra.isNotEmpty ? '- Extra constraint: $extra' : ''}

LANGUAGE RULE — MANDATORY
- Detect the dominant SPOKEN language from TRANSCRIPT only. Ignore the video title.
- Write hook_text and keywords in that same language.
- Indonesian transcript → Indonesian titles. English transcript → English titles.
- If mixed, use the language spoken in the selected clip; if still unclear, use the
  dominant language across the transcript.
- Never translate Indonesian speech into English.

REQUIRED JSON SHAPE
{"clips":[{"start_time":"00:00:05.000","end_time":"00:01:10.000","hook_text":"Judul sesuai bahasa ucapan","score":92,"keywords":["kata"]}]}

TRANSCRIPT [HH:MM:SS.mmm-HH:MM:SS.mmm]
--------------------------------------
${transcript.trim().isEmpty ? '(empty transcript)' : transcript.trim()}

END OF TRANSCRIPT.
NOW OUTPUT THE JSON OBJECT. START WITH { AND STOP AFTER THE MATCHING }.
''';
}

OwnAiParseResult parseOwnAiClipPaste(String text) {
  final raw = text.trim();
  if (raw.isEmpty) {
    return const OwnAiParseResult.err('Paste dulu balasan dari AI kamu.');
  }

  final hooks = ClipAiService.parseHooks(raw, const Duration(hours: 10));
  if (hooks.isNotEmpty) {
    return OwnAiParseResult.ok([
      for (final h in hooks)
        OwnAiClipSuggestion(
          startTime: secondsToTimestamp(h.startSec),
          endTime: secondsToTimestamp(h.endSec),
          hookText: h.reason ?? 'Clip',
          score: h.score ?? 70,
        ),
    ]);
  }

  return const OwnAiParseResult.err(
    'JSON tidak ketemu. Di chat AI ketik: "balas JSON saja", '
    'atau copy perintah JSON dari file export.',
  );
}
