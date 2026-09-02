import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_keys_service.dart';
import '../services/app_update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/update_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _groq = TextEditingController();
  final _gemini = TextEditingController();
  final _openrouter = TextEditingController();
  ClipHookProvider _hookProvider = ClipHookProvider.auto;
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
    final openrouter = await ApiKeysService.instance.openrouterKey();
    final prefer = await ApiKeysService.instance.hookProvider();
    if (!mounted) return;
    setState(() {
      _groq.text = groq;
      _gemini.text = gemini;
      _openrouter.text = openrouter;
      _hookProvider = prefer;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ApiKeysService.instance.saveGroqKey(_groq.text);
    await ApiKeysService.instance.saveGeminiKey(_gemini.text);
    await ApiKeysService.instance.saveOpenrouterKey(_openrouter.text);
    await ApiKeysService.instance.saveHookProvider(_hookProvider);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('API key tersimpan')));
  }

  @override
  void dispose() {
    _groq.dispose();
    _gemini.dispose();
    _openrouter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                48 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                Text(
                  'API key untuk Get Clip',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sama seperti Klippod. Groq/Gemini untuk Whisper; '
                  'pilih provider hook di bawah (bisa OpenRouter dulu). '
                  'OpenRouter tidak punya Whisper.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ClipHookProvider>(
                  initialValue: _hookProvider,
                  decoration: const InputDecoration(
                    labelText: 'Cari hook pakai',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final p in ClipHookProvider.values)
                      DropdownMenuItem(value: p, child: Text(p.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _hookProvider = v);
                  },
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
                const SizedBox(height: 8),
                TextField(
                  controller: _openrouter,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'OpenRouter API key',
                    hintText: 'sk-or-...',
                    border: OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse('https://openrouter.ai/keys'),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: const Text('Ambil key OpenRouter'),
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
                const SizedBox(height: 32),
                ValueListenableBuilder(
                  valueListenable: AppUpdateService.instance.available,
                  builder: (context, update, _) {
                    final current = AppUpdateService.instance.currentVersion;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aplikasi',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          current.isEmpty
                              ? 'Versi terpasang'
                              : 'Versi terpasang: $current',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 12),
                        if (update != null)
                          FilledButton.icon(
                            onPressed: () => startAppUpdate(context),
                            icon: const Icon(Icons.system_update_alt_rounded),
                            label: Text('Update ke v${update.version}'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              backgroundColor: AppColors.primary,
                            ),
                          )
                        else
                          OutlinedButton(
                            onPressed: () async {
                              final found = await AppUpdateService.instance
                                  .check();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    found == null
                                        ? 'Sudah versi terbaru'
                                        : 'Update v${found.version} tersedia',
                                  ),
                                ),
                              );
                            },
                            child: const Text('Cek update'),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
    );
  }
}
