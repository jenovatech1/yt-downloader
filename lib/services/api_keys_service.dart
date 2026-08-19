import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiKeysService {
  ApiKeysService._();
  static final instance = ApiKeysService._();

  static const _groqKey = 'groq_key';
  static const _geminiKey = 'gemini_key';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String> groqKey() async =>
      (await _storage.read(key: _groqKey))?.trim() ?? '';

  Future<String> geminiKey() async =>
      (await _storage.read(key: _geminiKey))?.trim() ?? '';

  Future<void> saveGroqKey(String value) =>
      _storage.write(key: _groqKey, value: value.trim());

  Future<void> saveGeminiKey(String value) =>
      _storage.write(key: _geminiKey, value: value.trim());

  Future<bool> hasAnyKey() async {
    final groq = await groqKey();
    final gemini = await geminiKey();
    return groq.isNotEmpty || gemini.isNotEmpty;
  }
}
