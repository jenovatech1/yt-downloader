import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

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

class ClipAiService {
  ClipAiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _groqWhisper = 'whisper-large-v3-turbo';
  static const _groqClip = 'llama-3.3-70b-versatile';
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
    final errors = <String>[];
    if (groqKey.isNotEmpty) {
      try {
        return await _groqTranscribe(audioFile, groqKey);
      } catch (e) {
        errors.add('Groq: $e');
      }
    }
    if (geminiKey.isNotEmpty) {
      try {
        return await _geminiTranscribe(audioFile, geminiKey);
      } catch (e) {
        errors.add('Gemini: $e');
      }
    }
    if (groqKey.isNotEmpty) {
      try {
        return await _groqTranscribe(audioFile, groqKey);
      } catch (e) {
        errors.add('Groq retry: $e');
      }
    }
    throw Exception(
      errors.isEmpty
          ? 'Isi API key Groq atau Gemini di Pengaturan dulu.'
          : 'Transkrip gagal:\n${errors.join('\n')}',
    );
  }

  Future<List<HookCandidate>> suggestHooks({
    required String transcript,
    required Duration videoDuration,
    required String groqKey,
    required String geminiKey,
    String? youtubeUrl,
  }) async {
    final errors = <String>[];
    final hasYt = youtubeUrl != null && youtubeUrl.contains('youtube');

    Future<List<HookCandidate>> gemini() => _geminiHooks(
      transcript: transcript,
      videoDuration: videoDuration,
      apiKey: geminiKey,
      youtubeUrl: youtubeUrl,
    );
    Future<List<HookCandidate>> groq() => _groqHooks(
      transcript: transcript,
      videoDuration: videoDuration,
      apiKey: groqKey,
    );

    if (geminiKey.isNotEmpty && (hasYt || groqKey.isEmpty)) {
      try {
        final hooks = await gemini();
        if (hooks.isNotEmpty) return hooks;
      } catch (e) {
        errors.add('Gemini: $e');
      }
    }
    if (groqKey.isNotEmpty) {
      try {
        final hooks = await groq();
        if (hooks.isNotEmpty) return hooks;
      } catch (e) {
        errors.add('Groq: $e');
      }
    }
    if (geminiKey.isNotEmpty) {
      try {
        final hooks = await gemini();
        if (hooks.isNotEmpty) return hooks;
      } catch (e) {
        errors.add('Gemini retry: $e');
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
    final text = (json['text'] ?? '').toString().trim();
    if (text.isEmpty) throw Exception('Transkrip Groq kosong');
    return text;
  }

  Future<String> _geminiTranscribe(File file, String apiKey) async {
    final bytes = await file.readAsBytes();
    if (bytes.length > 18 * 1024 * 1024) {
      throw Exception('Audio terlalu besar untuk Gemini. Tambahkan key Groq.');
    }
    final json = await _geminiGenerate(
      apiKey: apiKey,
      parts: [
        {
          'text':
              'Transcribe this audio to plain text in the spoken language. '
              'Return JSON {"text":"..."}.',
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
    final match = RegExp(r'"text"\s*:\s*"((?:\\.|[^"\\])*)"').firstMatch(text);
    if (match != null) {
      return jsonDecode('"${match.group(1)!}"') as String;
    }
    final decoded = jsonDecode(text);
    if (decoded is Map && decoded['text'] != null) {
      return decoded['text'].toString();
    }
    if (text.trim().isEmpty) throw Exception('Transkrip Gemini kosong');
    return text.trim();
  }

  Future<List<HookCandidate>> _groqHooks({
    required String transcript,
    required Duration videoDuration,
    required String apiKey,
  }) async {
    final prompt = _hookPrompt(transcript, videoDuration);
    final response = await _client
        .post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': _groqClip,
            'temperature': 0.45,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          }),
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
    final prompt = _hookPrompt(transcript, videoDuration);
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
                'temperature': 0.45,
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

  String _hookPrompt(String transcript, Duration videoDuration) {
    return 'Pilih hook viral dari video durasi ${videoDuration.inSeconds}s. '
        'Target 5–10 klip, durasi 20–90 detik, sebar di awal/tengah/akhir, '
        'hindari overlap, end di akhir kalimat. '
        'Format JSON array: '
        '[{"start":10,"end":95,"reason":"judul hook","score":85}]. '
        'Transcript:\n$transcript';
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
    final match = RegExp(r'\[[\s\S]*\]').firstMatch(content);
    if (match == null) return const [];
    final decoded = jsonDecode(match.group(0)!);
    if (decoded is! List) return const [];
    final maxSec = videoDuration.inSeconds.toDouble();
    final out = <HookCandidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final start = _seconds(item['start']);
      final end = _seconds(item['end']);
      if (start == null || end == null || end <= start) continue;
      var s = start.clamp(0, maxSec).toDouble();
      var e = end.clamp(0, maxSec).toDouble();
      if (e - s < 15) continue;
      if (e - s > 180) e = s + 180;
      final reason = (item['reason'] ?? item['caption'] ?? '').toString().trim();
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
      if (out.length >= 10) break;
    }
    return out;
  }

  static double? _seconds(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }
}
