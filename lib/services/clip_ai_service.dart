import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../config/get_clip_config.dart';
import '../models/clip_transcript.dart';
import 'api_keys_service.dart';
import 'clip_plan_shards.dart';
import 'openrouter_service.dart';
import 'yt_dlp_service.dart';

class HookCandidate {
  const HookCandidate({
    required this.startSec,
    required this.endSec,
    this.reason,
    this.score,
  });

  final double startSec;
  final double endSec;
  final String? reason;
  final double? score;
}

/// Whisper + hook — diselaraskan dengan desktop Klippod.
class ClipAiService {
  ClipAiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _whisperModels = ['whisper-large-v3-turbo', 'whisper-large-v3'];

  /// Desktop: gpt-oss-120b / gpt-oss-20b / qwen — TPM terpisah, di-shard parallel.
  static const _clipModels = [
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
    'qwen/qwen3.6-27b',
  ];
  static const _geminiModels = [
    'gemini-2.0-flash',
    'gemini-2.5-flash',
    'gemini-1.5-flash',
  ];

  Future<ClipTranscript> transcribe({
    required File audioFile,
    required String groqKey,
    required String geminiKey,
  }) async {
    final size = await audioFile.length();
    final mb = size / (1024 * 1024);
    final errors = <String>[];

    if (groqKey.isNotEmpty) {
      if (size > YtDlpService.groqMaxUploadBytes) {
        throw Exception(
          'Audio ${mb.toStringAsFixed(1)} MB melebihi limit Groq Whisper (~23 MB). '
          'Video terlalu panjang — coba yang lebih pendek.',
        );
      }
      try {
        return await _groqTranscribe(audioFile, groqKey);
      } catch (e) {
        errors.add('Groq: ${_friendlyHttp(e)}');
        if (_isSizeError(e)) {
          throw Exception(errors.join('\n'));
        }
      }
    }

    if (geminiKey.isNotEmpty) {
      if (size > 18 * 1024 * 1024) {
        errors.add(
          'Gemini dilewati: audio ${mb.toStringAsFixed(1)} MB '
          '(batas inline Gemini ~18 MB).',
        );
      } else {
        try {
          return await _geminiTranscribe(audioFile, geminiKey);
        } catch (e) {
          errors.add('Gemini: ${_friendlyHttp(e)}');
        }
      }
    }

    throw Exception(
      errors.isEmpty
          ? 'Isi API key Groq di Pengaturan dulu.'
          : 'Transkrip gagal:\n${errors.join('\n')}',
    );
  }

  static bool _isSizeError(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('too large') ||
        s.contains('entity too large') ||
        s.contains('413') ||
        s.contains('payload') ||
        s.contains('request_too_large') ||
        s.contains('maximum content size') ||
        s.contains('file size');
  }

  static String _friendlyHttp(Object e) {
    final s = e.toString();
    if (_isSizeError(e)) {
      return 'file terlalu besar untuk Whisper (~23 MB).';
    }
    if (s.contains('SocketException') || s.contains('ClientException')) {
      return 'jaringan gagal / timeout. Coba lagi.';
    }
    if (s.contains('TimeoutException')) {
      return 'timeout. Coba lagi atau video lebih pendek.';
    }
    if (s.length > 220) return '${s.substring(0, 220)}…';
    return s;
  }

  Future<List<HookCandidate>> suggestHooks({
    required String transcript,
    required Duration videoDuration,
    required String groqKey,
    required String geminiKey,
    String openrouterKey = '',
    ClipHookProvider prefer = ClipHookProvider.auto,
    String? youtubeUrl,
  }) async {
    final errors = <String>[];

    Future<List<HookCandidate>?> tryGroq() async {
      if (groqKey.isEmpty) return null;
      try {
        final hooks = await _groqHooks(
          transcript: transcript,
          videoDuration: videoDuration,
          apiKey: groqKey,
        );
        if (hooks.isNotEmpty) return hooks;
      } catch (e) {
        errors.add('Groq: $e');
      }
      return null;
    }

    Future<List<HookCandidate>?> tryGemini() async {
      if (geminiKey.isEmpty) return null;
      try {
        final hooks = await _geminiHooks(
          transcript: transcript,
          videoDuration: videoDuration,
          apiKey: geminiKey,
          youtubeUrl: youtubeUrl,
        );
        if (hooks.isNotEmpty) return hooks;
      } catch (e) {
        errors.add('Gemini: $e');
      }
      return null;
    }

    Future<List<HookCandidate>?> tryOpenRouter() async {
      if (openrouterKey.isEmpty) return null;
      try {
        final hooks = await OpenRouterService(client: _client).suggestHooks(
          transcript: transcript,
          videoDuration: videoDuration,
          apiKey: openrouterKey,
        );
        if (hooks.isNotEmpty) return hooks;
      } catch (e) {
        errors.add('OpenRouter: $e');
      }
      return null;
    }

    final order = switch (prefer) {
      ClipHookProvider.openrouter => [tryOpenRouter, tryGroq, tryGemini],
      ClipHookProvider.gemini => [tryGemini, tryGroq, tryOpenRouter],
      ClipHookProvider.groq => [tryGroq, tryGemini, tryOpenRouter],
      ClipHookProvider.auto => [tryGroq, tryGemini, tryOpenRouter],
      ClipHookProvider.ownAi => <Future<List<HookCandidate>?> Function()>[],
    };

    for (final run in order) {
      final hooks = await run();
      if (hooks != null && hooks.isNotEmpty) return hooks;
    }

    throw Exception(
      errors.isEmpty
          ? 'Tidak ada hook yang ditemukan.'
          : 'Deteksi hook gagal:\n${errors.join('\n')}',
    );
  }

  Future<ClipTranscript> _groqTranscribe(File file, String apiKey) async {
    final bytes = await file.readAsBytes();
    Object? last;
    for (final model in _whisperModels) {
      try {
        final built = _multipart(
          model: model,
          fileName: file.uri.pathSegments.last,
          fileBytes: bytes,
        );
        final response = await _client
            .post(
              Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'),
              headers: {
                'Authorization': 'Bearer $apiKey',
                'Content-Type':
                    'multipart/form-data; boundary=${built.boundary}',
              },
              body: built.bytes,
            )
            .timeout(const Duration(seconds: 180));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return _parseWhisperResponse(response.body);
        }
        last = Exception('${response.statusCode} ${response.body}');
        final body = response.body.toLowerCase();
        final canFallback =
            response.statusCode == 400 ||
            response.statusCode == 404 ||
            body.contains('model') ||
            body.contains('decommission') ||
            body.contains('not found') ||
            body.contains('unsupported');
        if (!canFallback) throw last;
      } catch (e) {
        last = e;
        final s = '$e'.toLowerCase();
        final canFallback =
            s.contains('400') ||
            s.contains('404') ||
            s.contains('model') ||
            s.contains('not found');
        if (!canFallback) rethrow;
      }
    }
    throw last ?? Exception('Whisper gagal');
  }

  ClipTranscript _parseWhisperResponse(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final cues = <ClipTranscriptCue>[];
    final globalWords = _parseWhisperWords(json['words']);
    final segments = json['segments'] as List?;
    if (segments != null) {
      for (final seg in segments) {
        if (seg is! Map) continue;
        final start = (seg['start'] as num?)?.toDouble() ?? 0;
        final end = (seg['end'] as num?)?.toDouble() ?? start;
        final text = (seg['text'] ?? '').toString().trim();
        if (text.isEmpty) continue;
        final segmentWords = _parseWhisperWords(seg['words']);
        final words = segmentWords.isNotEmpty
            ? segmentWords
            : globalWords
                  .where((w) => w.endSec > start && w.startSec < end)
                  .toList();
        cues.add(
          ClipTranscriptCue(
            startSec: start,
            endSec: end,
            text: text,
            wordTimings: words,
          ),
        );
      }
    }
    if (cues.isNotEmpty) {
      final buf = StringBuffer();
      for (final c in cues) {
        buf.writeln('[${_fmtTs(c.startSec)}-${_fmtTs(c.endSec)}] ${c.text}');
      }
      return ClipTranscript(stampedText: buf.toString().trim(), cues: cues);
    }
    final text = (json['text'] ?? '').toString().trim();
    if (text.isEmpty) throw Exception('Transkrip Groq kosong');
    return ClipTranscript(stampedText: text, cues: const []);
  }

  List<ClipTranscriptWord> _parseWhisperWords(Object? raw) {
    if (raw is! List) return const [];
    final words = <ClipTranscriptWord>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final word = (item['word'] ?? item['text'] ?? '').toString().trim();
      final start = (item['start'] as num?)?.toDouble();
      final end = (item['end'] as num?)?.toDouble();
      if (word.isEmpty || start == null || end == null || end <= start) {
        continue;
      }
      words.add(ClipTranscriptWord(word: word, startSec: start, endSec: end));
    }
    return words;
  }

  Future<ClipTranscript> _geminiTranscribe(File file, String apiKey) async {
    final bytes = await file.readAsBytes();
    final json = await _geminiGenerate(
      apiKey: apiKey,
      parts: [
        {
          'text':
              'Transcribe this audio. Return JSON '
              '{"segments":[{"start":0.0,"end":1.2,"text":"..."}]} '
              'with approximate timestamps in seconds.',
        },
        {
          'inline_data': {
            'mime_type': file.path.toLowerCase().endsWith('.mp3')
                ? 'audio/mpeg'
                : 'audio/mp4',
            'data': base64Encode(bytes),
          },
        },
      ],
    );
    final text = _extractGeminiText(json);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['segments'] is List) {
        final cues = <ClipTranscriptCue>[];
        for (final seg in decoded['segments'] as List) {
          if (seg is! Map) continue;
          final start = _seconds(seg['start']) ?? 0;
          final end = _seconds(seg['end']) ?? start;
          final t = (seg['text'] ?? '').toString().trim();
          if (t.isEmpty) continue;
          cues.add(ClipTranscriptCue(startSec: start, endSec: end, text: t));
        }
        if (cues.isNotEmpty) {
          final buf = StringBuffer();
          for (final c in cues) {
            buf.writeln(
              '[${_fmtTs(c.startSec)}-${_fmtTs(c.endSec)}] ${c.text}',
            );
          }
          return ClipTranscript(stampedText: buf.toString().trim(), cues: cues);
        }
      }
      if (decoded is Map && decoded['text'] != null) {
        final t = decoded['text'].toString();
        return ClipTranscript(stampedText: t, cues: const []);
      }
    } catch (_) {}
    if (text.trim().isEmpty) throw Exception('Transkrip Gemini kosong');
    return ClipTranscript(stampedText: text.trim(), cues: const []);
  }

  /// Mirror desktop `generateClipPlan`: pecah transkrip → shard ke 3 model (TPM parallel).
  Future<List<HookCandidate>> _groqHooks({
    required String transcript,
    required Duration videoDuration,
    required String apiKey,
  }) async {
    final durSec = videoDuration.inSeconds;
    final shards = buildClipPlanShards(
      transcript,
      modelChain: _clipModels,
      minClips: 3,
      maxClips: GetClipConfig.maxClips,
    );
    if (shards.isEmpty) {
      throw Exception('Transkrip kosong untuk clip plan');
    }

    final byModel = <String, List<ClipPlanShard>>{};
    for (final s in shards) {
      byModel.putIfAbsent(s.model, () => []).add(s);
    }

    final parts = await Future.wait([
      for (final entry in byModel.entries)
        _runClipShardQueue(
          model: entry.key,
          shards: entry.value,
          apiKey: apiKey,
          videoDuration: videoDuration,
          durSec: durSec,
        ),
    ]);

    final merged = <HookCandidate>[];
    final seen = <String>{};
    for (final list in parts) {
      for (final h in list) {
        final key =
            '${h.startSec.toStringAsFixed(1)}-${h.endSec.toStringAsFixed(1)}';
        if (seen.add(key)) merged.add(h);
      }
    }
    merged.sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0));
    if (merged.isEmpty) {
      throw Exception(
        'Generate clips gagal di semua shard (TPM/format). '
        'Coba lagi sebentar atau isi Gemini di Pengaturan.',
      );
    }
    return merged.take(GetClipConfig.maxClips).toList();
  }

  Future<List<HookCandidate>> _runClipShardQueue({
    required String model,
    required List<ClipPlanShard> shards,
    required String apiKey,
    required Duration videoDuration,
    required int durSec,
  }) async {
    final out = <HookCandidate>[];
    for (final shard in shards) {
      final excerpt = shard.text.length > ClipPlanBudget.maxTranscriptChars
          ? ClipPlanBudget.trimTranscript(shard.text)
          : shard.text;
      try {
        final hooks = await _requestClipPlanOnce(
          model: model,
          excerpt: excerpt,
          minClips: shard.minClips,
          maxClips: shard.maxClips,
          apiKey: apiKey,
          videoDuration: videoDuration,
          durSec: durSec,
        );
        out.addAll(hooks);
      } catch (e) {
        final s = '$e'.toLowerCase();
        final isTpm = s.contains('429') || s.contains('rate limit');
        if (!isTpm) continue;
        // Desktop: tunggu TPM reset model ini, retry sekali — jangan lompat model.
        await Future<void>.delayed(const Duration(seconds: 28));
        final smaller = ClipPlanBudget.trimTranscript(
          excerpt,
          maxChars: math.max(800, excerpt.length ~/ 2),
        );
        try {
          final hooks = await _requestClipPlanOnce(
            model: model,
            excerpt: smaller,
            minClips: shard.minClips,
            maxClips: math.min(shard.maxClips, 6),
            apiKey: apiKey,
            videoDuration: videoDuration,
            durSec: durSec,
          );
          out.addAll(hooks);
        } catch (_) {
          continue;
        }
      }
    }
    return out;
  }

  Future<List<HookCandidate>> _requestClipPlanOnce({
    required String model,
    required String excerpt,
    required int minClips,
    required int maxClips,
    required String apiKey,
    required Duration videoDuration,
    required int durSec,
  }) async {
    final countLine =
        'Hasilkan $minClips-$maxClips kandidat klip (usahakan mendekati $maxClips '
        'jika ada cukup momen kuat). Jangan hanya 1-3 klip.';
    final system =
        'Buat rencana klip Reels/TikTok dari podcast/interview. '
        'Durasi tiap klip ${GetClipConfig.durationPrompt}. '
        'Video ~${(durSec / 60).round()} menit. $countLine '
        'Copy start_time/end_time dari timestamp transkrip (persis). '
        'hook_text 4-10 kata, bahasa = bahasa transkrip. '
        'Sebar awal/tengah/akhir. Hindari overlap & filler. '
        'Balas HANYA JSON object {"clips":[...]}.';
    final user =
        'Gunakan transkrip berikut dan BALAS HANYA JSON: '
        '{"clips":[{"start_time":"00:00:05.000","end_time":"00:01:10.000",'
        '"hook_text":"Topik singkat","score":92,"keywords":["trik"]}]}. '
        '$countLine Transkrip: $excerpt';

    final body = <String, dynamic>{
      'model': model,
      'temperature': 0.35,
      'max_tokens': ClipPlanBudget.maxOutputTokens,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': 'Tidak ada hook awal.'},
        {'role': 'user', 'content': user},
      ],
    };
    if (model.contains('gpt-oss')) {
      body['reasoning_effort'] = 'low';
    } else if (model.contains('qwen')) {
      body['reasoning_effort'] = 'none';
    }

    final response = await _client
        .post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 120));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('${response.statusCode} ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final content =
        (json['choices'] as List?)?.first?['message']?['content'] as String? ??
        '';
    return parseHooks(content, videoDuration);
  }

  Future<List<HookCandidate>> _geminiHooks({
    required String transcript,
    required Duration videoDuration,
    required String apiKey,
    String? youtubeUrl,
  }) async {
    final prompt =
        'Pilih hook viral dari video durasi ${videoDuration.inSeconds}s. '
        'Target ${GetClipConfig.maxClips} klip maks, durasi ${GetClipConfig.durationPrompt}, '
        'sebar di awal/tengah/akhir.\n\n'
        'Balas HANYA JSON: {"clips":[{"start_time":"00:00:05.000",'
        '"end_time":"00:01:10.000","hook_text":"...","score":90}]}\n\n'
        'Transkrip:\n${ClipPlanBudget.trimTranscript(transcript)}';
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      if (youtubeUrl != null && youtubeUrl.contains('watch?v='))
        {
          'file_data': {'file_uri': youtubeUrl, 'mime_type': 'video/mp4'},
        },
    ];
    final json = await _geminiGenerate(apiKey: apiKey, parts: parts);
    return parseHooks(_extractGeminiText(json), videoDuration);
  }

  Future<Map<String, dynamic>> _geminiGenerate({
    required String apiKey,
    required List<Map<String, dynamic>> parts,
  }) async {
    Object? last;
    for (final model in _geminiModels) {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$model:generateContent?key=${Uri.encodeComponent(apiKey)}',
      );
      final response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {'parts': parts},
              ],
              'generationConfig': {
                'temperature': 0.35,
                'responseMimeType': 'application/json',
              },
            }),
          )
          .timeout(const Duration(seconds: 180));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      last = Exception('${response.statusCode} ${response.body}');
      final body = response.body.toLowerCase();
      if (!body.contains('not found') &&
          !body.contains('not supported') &&
          response.statusCode != 404) {
        throw last;
      }
    }
    throw last ?? Exception('Semua model Gemini gagal');
  }

  String _extractGeminiText(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List?;
    final content = candidates?.first as Map?;
    final parts = content?['content']?['parts'] as List?;
    final buf = StringBuffer();
    for (final part in parts ?? const []) {
      if (part is Map && part['text'] != null) buf.write(part['text']);
    }
    return buf.toString();
  }

  ({String boundary, List<int> bytes}) _multipart({
    required String model,
    required String fileName,
    required List<int> fileBytes,
  }) {
    final boundary =
        'ytdl${DateTime.now().microsecondsSinceEpoch}${math.Random().nextInt(99999)}';
    final buf = <int>[];
    void field(String name, String value) {
      buf.addAll(utf8.encode('--$boundary\r\n'));
      buf.addAll(
        utf8.encode('Content-Disposition: form-data; name="$name"\r\n\r\n'),
      );
      buf.addAll(utf8.encode('$value\r\n'));
    }

    field('model', model);
    field('response_format', 'verbose_json');
    field('temperature', '0');
    field('timestamp_granularities[]', 'word');
    field('timestamp_granularities[]', 'segment');
    buf.addAll(utf8.encode('--$boundary\r\n'));
    buf.addAll(
      utf8.encode(
        'Content-Disposition: form-data; name="file"; filename="$fileName"\r\n',
      ),
    );
    buf.addAll(utf8.encode('Content-Type: application/octet-stream\r\n\r\n'));
    buf.addAll(fileBytes);
    buf.addAll(utf8.encode('\r\n--$boundary--\r\n'));
    return (boundary: boundary, bytes: buf);
  }

  static List<HookCandidate> parseHooks(
    String content,
    Duration videoDuration,
  ) {
    final parsed = _parseJson(content);
    if (parsed == null) return const [];

    List list;
    if (parsed is List) {
      list = parsed;
    } else if (parsed is Map && parsed['clips'] is List) {
      list = parsed['clips'] as List;
    } else {
      return const [];
    }

    final maxSec = videoDuration.inSeconds.toDouble();
    final out = <HookCandidate>[];
    final seen = <String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final start = _seconds(item['start_time'] ?? item['start']);
      final end = _seconds(item['end_time'] ?? item['end']);
      if (start == null || end == null || end <= start) continue;
      var s = start.clamp(0, maxSec).toDouble();
      var e = end.clamp(0, maxSec).toDouble();
      if (e - s < GetClipConfig.minClipSec) continue;
      if (e - s > GetClipConfig.maxClipSec) {
        e = s + GetClipConfig.maxClipSec;
      }
      final key = '${s.toStringAsFixed(1)}-${e.toStringAsFixed(1)}';
      if (seen.contains(key)) continue;
      seen.add(key);
      final reason =
          (item['hook_text'] ?? item['reason'] ?? item['caption'] ?? '')
              .toString()
              .trim();
      final scoreRaw = item['score'] ?? item['hookScore'];
      double? score;
      if (scoreRaw is num) {
        score = scoreRaw.toDouble();
      } else if (scoreRaw is String) {
        score = double.tryParse(scoreRaw);
      }
      out.add(
        HookCandidate(
          startSec: s,
          endSec: e,
          reason: reason.isEmpty ? null : reason,
          score: score,
        ),
      );
      if (out.length >= GetClipConfig.maxClips) break;
    }
    out.sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0));
    return out;
  }

  static dynamic _parseJson(String content) {
    try {
      return jsonDecode(content);
    } catch (_) {
      final obj = RegExp(r'\{[\s\S]*\}').firstMatch(content);
      if (obj != null) {
        try {
          return jsonDecode(obj.group(0)!);
        } catch (_) {}
      }
      final arr = RegExp(r'\[[\s\S]*\]').firstMatch(content);
      if (arr != null) {
        try {
          return jsonDecode(arr.group(0)!);
        } catch (_) {}
      }
      return null;
    }
  }

  static double? _seconds(Object? value) {
    if (value is num) return value.toDouble();
    if (value is! String) return null;
    final raw = value.trim();
    final asNum = double.tryParse(raw);
    if (asNum != null) return asNum;
    final parts = raw.split(':');
    if (parts.length == 3) {
      final h = double.tryParse(parts[0]) ?? 0;
      final m = double.tryParse(parts[1]) ?? 0;
      final s = double.tryParse(parts[2]) ?? 0;
      return h * 3600 + m * 60 + s;
    }
    if (parts.length == 2) {
      final m = double.tryParse(parts[0]) ?? 0;
      final s = double.tryParse(parts[1]) ?? 0;
      return m * 60 + s;
    }
    return null;
  }

  static String _fmtTs(double sec) {
    final s = sec < 0 ? 0.0 : sec;
    final h = (s ~/ 3600);
    final m = ((s % 3600) ~/ 60);
    final r = s % 60;
    final whole = r.floor();
    final frac = ((r - whole) * 1000).round().clamp(0, 999);
    String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${p(h)}:${p(m)}:${p(whole)}.${p(frac, 3)}';
  }
}
