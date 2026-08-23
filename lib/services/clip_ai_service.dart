import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

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

/// Hook AI — model & prompt diselaraskan dengan desktop Klippod (Agu 2026).
class ClipAiService {
  ClipAiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _groqWhisper = 'whisper-large-v3-turbo';
  /// llama-3.3-70b-versatile shutdown 16 Agu 2026 → gpt-oss-120b.
  static const _clipModels = [
    'openai/gpt-oss-120b',
    'qwen/qwen3.6-27b',
    'openai/gpt-oss-20b',
  ];
  static const _clipPlanMaxChars = 22000;
  static const _geminiModels = [
    'gemini-2.0-flash',
    'gemini-2.5-flash',
    'gemini-1.5-flash',
  ];

  Future<String> transcribe({
    required File audioFile,
    required String groqKey,
    required String geminiKey,
  }) async {
    final size = await audioFile.length();
    final mb = size / (1024 * 1024);
    final errors = <String>[];

    // Groq Whisper hard limit ~25 MB. Jangan fallback ke Gemini "too large"
    // yang membingungkan kalau file sudah di luar kapasitas Whisper.
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
        // Size / entity-too-large: jangan lanjut Gemini (pesan "terlalu besar" palsu).
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
    String? youtubeUrl,
  }) async {
    final errors = <String>[];

    // Desktop: Groq dulu, lalu Gemini.
    if (groqKey.isNotEmpty) {
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
    }
    if (geminiKey.isNotEmpty) {
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
    }
    throw Exception(
      errors.isEmpty
          ? 'Tidak ada hook yang ditemukan.'
          : 'Deteksi hook gagal:\n${errors.join('\n')}',
    );
  }

  Future<String> _groqTranscribe(File file, String apiKey) async {
    final bytes = await file.readAsBytes();
    final built = _multipart(
      model: _groqWhisper,
      fileName: file.uri.pathSegments.last,
      fileBytes: bytes,
    );
    final response = await _client
        .post(
          Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'multipart/form-data; boundary=${built.boundary}',
          },
          body: built.bytes,
        )
        .timeout(const Duration(seconds: 180));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('${response.statusCode} ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final segments = json['segments'] as List?;
    if (segments != null && segments.isNotEmpty) {
      final buf = StringBuffer();
      for (final seg in segments) {
        if (seg is! Map) continue;
        final start = (seg['start'] as num?)?.toDouble() ?? 0;
        final end = (seg['end'] as num?)?.toDouble() ?? start;
        final text = (seg['text'] ?? '').toString().trim();
        if (text.isEmpty) continue;
        buf.writeln('[${_fmtTs(start)}-${_fmtTs(end)}] $text');
      }
      final stamped = buf.toString().trim();
      if (stamped.isNotEmpty) return stamped;
    }
    final text = (json['text'] ?? '').toString().trim();
    if (text.isEmpty) throw Exception('Transkrip Groq kosong');
    return text;
  }

  Future<String> _geminiTranscribe(File file, String apiKey) async {
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
            'mime_type': 'audio/mp4',
            'data': base64Encode(bytes),
          },
        },
      ],
    );
    final text = _extractGeminiText(json);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['segments'] is List) {
        final buf = StringBuffer();
        for (final seg in decoded['segments'] as List) {
          if (seg is! Map) continue;
          final start = _seconds(seg['start']) ?? 0;
          final end = _seconds(seg['end']) ?? start;
          final t = (seg['text'] ?? '').toString().trim();
          if (t.isEmpty) continue;
          buf.writeln('[${_fmtTs(start)}-${_fmtTs(end)}] $t');
        }
        final stamped = buf.toString().trim();
        if (stamped.isNotEmpty) return stamped;
      }
      if (decoded is Map && decoded['text'] != null) {
        return decoded['text'].toString();
      }
    } catch (_) {}
    if (text.trim().isEmpty) throw Exception('Transkrip Gemini kosong');
    return text.trim();
  }

  Future<List<HookCandidate>> _groqHooks({
    required String transcript,
    required Duration videoDuration,
    required String apiKey,
  }) async {
    final excerpt = _trimTranscript(transcript);
    final durSec = videoDuration.inSeconds;
    final system =
        'Durasi tiap klip 30-90 detik (boleh sampai 180 jika konteks butuh). '
        'Buat rencana klip Reels/TikTok dari podcast/interview. '
        'Bahasa hook_text = bahasa transkrip. '
        'Transkrip berisi timestamp seperti [HH:MM:SS.mmm-HH:MM:SS.mmm]. '
        'Durasi video sekitar ${(durSec / 60).round()} menit. '
        'Target 5-10 klip. '
        'WAJIB pilih start_time/end_time dari timestamp yang ada (copy persis), '
        'end di akhir kalimat. '
        'hook_text 4-10 kata, clickbait/curiosity, tapi harus sesuai isi window. '
        'Balas HANYA JSON object {"clips":[...]}.';
    final user =
        'Gunakan transkrip berikut dan BALAS HANYA JSON: '
        '{"clips":[{"start_time":"00:00:05.000","end_time":"00:01:10.000",'
        '"hook_text":"Topik singkat","score":92,"keywords":["trik"]}]}. '
        'Transkrip: $excerpt';

    Object? last;
    for (final model in _clipModels) {
      try {
        final response = await _client
            .post(
              Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
              headers: {
                'Authorization': 'Bearer $apiKey',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'model': model,
                'temperature': 0.35,
                'max_tokens': 4096,
                'response_format': {'type': 'json_object'},
                'messages': [
                  {'role': 'system', 'content': system},
                  {'role': 'user', 'content': 'Tidak ada hook awal.'},
                  {'role': 'user', 'content': user},
                ],
              }),
            )
            .timeout(const Duration(seconds: 120));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final content = (json['choices'] as List?)
                  ?.first?['message']?['content'] as String? ??
              '';
          final hooks = parseHooks(content, videoDuration);
          if (hooks.isNotEmpty) return hooks;
          last = Exception('Model $model: response kosong / tidak parse');
          continue;
        }
        last = Exception('${response.statusCode} ${response.body}');
        final body = response.body.toLowerCase();
        final canFallback = response.statusCode == 400 ||
            response.statusCode == 404 ||
            body.contains('model') ||
            body.contains('decommission') ||
            body.contains('not found') ||
            body.contains('does not exist');
        if (!canFallback) throw last;
      } catch (e) {
        last = e;
        final msg = '$e'.toLowerCase();
        final canFallback = msg.contains('400') ||
            msg.contains('404') ||
            msg.contains('model') ||
            msg.contains('decommission') ||
            msg.contains('not found');
        if (!canFallback) rethrow;
      }
    }
    throw last ?? Exception('Semua model Groq clip gagal');
  }

  Future<List<HookCandidate>> _geminiHooks({
    required String transcript,
    required Duration videoDuration,
    required String apiKey,
    String? youtubeUrl,
  }) async {
    final prompt =
        '$_systemBrief(videoDuration)\n\n'
        'Balas HANYA JSON: {"clips":[{"start_time":"00:00:05.000",'
        '"end_time":"00:01:10.000","hook_text":"...","score":90}]}\n\n'
        'Transkrip:\n${_trimTranscript(transcript)}';
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      if (youtubeUrl != null && youtubeUrl.contains('watch?v='))
        {
          'file_data': {
            'file_uri': youtubeUrl,
            'mime_type': 'video/mp4',
          },
        },
    ];
    final json = await _geminiGenerate(apiKey: apiKey, parts: parts);
    return parseHooks(_extractGeminiText(json), videoDuration);
  }

  String _systemBrief(Duration videoDuration) {
    return 'Pilih hook viral dari video durasi ${videoDuration.inSeconds}s. '
        'Target 5–10 klip, durasi 30–90 detik, sebar di awal/tengah/akhir.';
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

  String _trimTranscript(String transcript) {
    final text = transcript.trim();
    if (text.length <= _clipPlanMaxChars) return text;
    final section = _clipPlanMaxChars ~/ 3;
    final midStart = math.max(0, text.length ~/ 2 - section ~/ 2);
    return '${text.substring(0, section)}\n--- BAGIAN TENGAH ---\n'
        '${text.substring(midStart, midStart + section)}\n'
        '--- BAGIAN AKHIR ---\n${text.substring(text.length - section)}';
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
      if (e - s < 15) continue;
      if (e - s > 180) e = s + 180;
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
      if (out.length >= 12) break;
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
