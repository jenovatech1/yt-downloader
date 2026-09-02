import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/get_clip_config.dart';
import 'clip_ai_service.dart';

/// Mirror desktop `src/lib/openrouter.ts` — clip plan saja (tidak ada Whisper).
class OpenRouterService {
  OpenRouterService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const apiUrl = 'https://openrouter.ai/api/v1';
  static const freeModel = 'openrouter/free';
  static const keysUrl = 'https://openrouter.ai/keys';
  static const maxTranscriptChars = 80000;
  static const maxOutputTokens = 32768;

  Future<void> verifyApiKey({required String apiKey}) async {
    final key = apiKey.trim();
    if (key.isEmpty) throw Exception('OpenRouter API key kosong');
    final res = await _client
        .get(
          Uri.parse('$apiUrl/models'),
          headers: {'Authorization': 'Bearer $key'},
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw Exception('API key OpenRouter tidak valid');
    }
    if (res.statusCode == 429) {
      throw Exception('OpenRouter rate limit saat verifikasi key');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('OpenRouter verify gagal (${res.statusCode})');
    }
  }

  Future<List<HookCandidate>> suggestHooks({
    required String transcript,
    required Duration videoDuration,
    required String apiKey,
  }) async {
    final trimmed = transcript.length > maxTranscriptChars
        ? '${transcript.substring(0, maxTranscriptChars ~/ 2)}\n...\n'
            '${transcript.substring(transcript.length - maxTranscriptChars ~/ 2)}'
        : transcript;
    final durSec = videoDuration.inSeconds;
    final prompt = [
      'Analis clip short-form (Reels/TikTok/Shorts). Bahasa hook = bahasa transkrip.',
      '⚠️ DURASI KLIP WAJIB ${GetClipConfig.durationPrompt}.',
      'Durasi video sekitar ${(durSec / 60).round()} menit ($durSec detik).',
      'Hasilkan 3-${GetClipConfig.maxClips} kandidat klip (usahakan mendekati ${GetClipConfig.maxClips}).',
      'Timestamp relatif ke awal, atau copy [HH:MM:SS] dari transkrip.',
      'reason 4-10 kata, bahasa sama dengan transkrip.',
      'OUTPUT JSON SAJA, tanpa markdown/thinking: '
          '{"clips":[{"start_time":"00:00:05.000","end_time":"00:01:10.000",'
          '"hook_text":"Short title","score":85}]}',
      'Sebarkan awal/tengah/akhir. Hindari overlap.',
      'Transkrip:',
      trimmed,
    ].join('\n');

    Object? last;
    for (final effort in ['none', 'minimal']) {
      try {
        final text = await _chat(
          apiKey: apiKey,
          prompt: prompt,
          reasoningEffort: effort,
        );
        final hooks = ClipAiService.parseHooks(text, videoDuration);
        if (hooks.isNotEmpty) return hooks.take(GetClipConfig.maxClips).toList();
        last = Exception('OpenRouter response kosong');
      } catch (e) {
        last = e;
        if (effort == 'minimal') rethrow;
      }
    }
    throw last ?? Exception('OpenRouter suggestHooks gagal');
  }

  Future<String> _chat({
    required String apiKey,
    required String prompt,
    required String reasoningEffort,
  }) async {
    Future<http.Response> post(bool includeReasoning) {
      final body = <String, dynamic>{
        'model': freeModel,
        'temperature': 0.2,
        'max_tokens': maxOutputTokens,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      };
      if (includeReasoning) {
        body['reasoning'] = {
          'effort': reasoningEffort,
          'exclude': reasoningEffort == 'none',
        };
      }
      return _client
          .post(
            Uri.parse('$apiUrl/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${apiKey.trim()}',
              'HTTP-Referer':
                  'https://github.com/jenovatech1/yt-downloader',
              'X-Title': 'YT Downloader',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));
    }

    var res = await post(true);
    if (res.statusCode == 400 || res.statusCode == 422) {
      final detail = res.body.toLowerCase();
      if (detail.contains('reason')) {
        res = await post(false);
      }
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('OpenRouter ${res.statusCode}: ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final choice = (json['choices'] as List?)?.first;
    if (choice is! Map) throw Exception('OpenRouter response kosong');
    final msg = choice['message'];
    if (msg is Map && msg['content'] != null) {
      final c = msg['content'];
      if (c is String && c.trim().isNotEmpty) return c;
      if (c is List) {
        final buf = StringBuffer();
        for (final p in c) {
          if (p is Map && p['text'] != null) buf.write(p['text']);
        }
        if (buf.isNotEmpty) return buf.toString();
      }
    }
    final reasoning = msg is Map
        ? (msg['reasoning'] ?? msg['reasoning_content'] ?? '').toString()
        : '';
    if (reasoning.trim().isNotEmpty) {
      final i = reasoning.indexOf(RegExp(r'[\[{]'));
      return i >= 0 ? reasoning.substring(i) : reasoning;
    }
    throw Exception('OpenRouter mengembalikan respons kosong');
  }
}
