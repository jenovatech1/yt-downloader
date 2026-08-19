import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_keys_service.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _groq = TextEditingController();
  final _gemini = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final groq = await ApiKeysService.instance.groqKey();
    final gemini = await ApiKeysService.instance.geminiKey();
    if (!mounted) return;
    setState(() {
      _groq.text = groq;
      _gemini.text = gemini;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ApiKeysService.instance.saveGroqKey(_groq.text);
    await ApiKeysService.instance.saveGeminiKey(_gemini.text);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('API key tersimpan')),
    );
  }

  @override
  void dispose() {
    _groq.dispose();
    _gemini.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'API key untuk Get Clip',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sama seperti Klippod. Groq untuk transkrip, Gemini untuk hook. '
                  'Kalau salah satu gagal, yang lain dipakai sebagai cadangan.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _groq,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Groq API key',
                    hintText: 'gsk_...',
                    border: OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse('https://console.groq.com/keys'),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: const Text('Ambil key Groq'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _gemini,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Gemini API key',
                    hintText: 'AIza...',
                    border: OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse('https://aistudio.google.com/apikey'),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: const Text('Ambil key Gemini'),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: AppColors.primary,
                  ),
                  child: Text(_saving ? 'Menyimpan...' : 'Simpan'),
                ),
              ],
            ),
    );
  }
}
