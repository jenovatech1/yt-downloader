import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Provider AI untuk cari hook Get Clip (Whisper tetap Groq/Gemini).
enum ClipHookProvider {
  auto,
  groq,
  gemini,
  openrouter,
  ownAi,
}

extension ClipHookProviderLabel on ClipHookProvider {
  String get label => switch (this) {
        ClipHookProvider.auto => 'Otomatis (Groq → Gemini → OpenRouter)',
        ClipHookProvider.groq => 'Groq',
        ClipHookProvider.gemini => 'Gemini',
        ClipHookProvider.openrouter => 'OpenRouter',
        ClipHookProvider.ownAi => 'AI sendiri (ChatGPT / Claude / Gemini)',
      };
}

class ApiKeysService {
  ApiKeysService._();
  static final instance = ApiKeysService._();

  static const _groqKey = 'groq_key';
  static const _geminiKey = 'gemini_key';
  static const _openrouterKey = 'openrouter_key';
  static const _hookProviderKey = 'clip_hook_provider';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String> groqKey() async =>
      (await _storage.read(key: _groqKey))?.trim() ?? '';

  Future<String> geminiKey() async =>
      (await _storage.read(key: _geminiKey))?.trim() ?? '';

  Future<String> openrouterKey() async =>
      (await _storage.read(key: _openrouterKey))?.trim() ?? '';

  Future<ClipHookProvider> hookProvider() async {
    final raw = (await _storage.read(key: _hookProviderKey))?.trim() ?? '';
    return ClipHookProvider.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => ClipHookProvider.auto,
    );
  }

  Future<void> saveGroqKey(String value) =>
      _storage.write(key: _groqKey, value: value.trim());

  Future<void> saveGeminiKey(String value) =>
      _storage.write(key: _geminiKey, value: value.trim());

  Future<void> saveOpenrouterKey(String value) =>
      _storage.write(key: _openrouterKey, value: value.trim());

  Future<void> saveHookProvider(ClipHookProvider value) =>
      _storage.write(key: _hookProviderKey, value: value.name);

  Future<bool> hasAnyKey() async {
    final groq = await groqKey();
    final gemini = await geminiKey();
    final openrouter = await openrouterKey();
    return groq.isNotEmpty || gemini.isNotEmpty || openrouter.isNotEmpty;
  }

  /// Whisper butuh Groq/Gemini — OpenRouter tidak punya STT.
  Future<bool> hasWhisperKey() async {
    final groq = await groqKey();
    final gemini = await geminiKey();
    return groq.isNotEmpty || gemini.isNotEmpty;
  }
}
