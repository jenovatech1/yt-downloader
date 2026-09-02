import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../services/app_update_service.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../widgets/update_dialog.dart';
import '../widgets/video_tile.dart';
import 'campaign_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  final _youtube = YoutubeService();

  List<Video> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppUpdateService.instance.check();
  }

  @override
  void dispose() {
    _controller.dispose();
    _youtube.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });

    try {
      final results = await _youtube.search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        if (results.isEmpty) {
          _error = 'Tidak ada hasil ditemukan';
        }
      });

      if (results.length == 1 && _youtube.tryParseVideoId(query) != null) {
        _openVideo(results.first);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Gagal mencari: ${YoutubeService.shortError(e)}';
      });
    }
  }

  Future<void> _pasteAndSearch() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard kosong')),
      );
      return;
    }
    _controller.text = text;
    await _search();
  }

  void _openVideo(Video video) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(video: video)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.asset(
                          'assets/app_logo.png',
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ShaderMask(
                              shaderCallback: (bounds) =>
                                  AppColors.gradient.createShader(bounds),
                              child: Text(
                                'YT Downloader',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Text(
                              'Cari judul atau tempel link YouTube',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ValueListenableBuilder(
                        valueListenable: AppUpdateService.instance.available,
                        builder: (context, update, _) {
                          return IconButton(
                            tooltip: 'Pengaturan',
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            ),
                            icon: Badge(
                              isLabelVisible: update != null,
                              child: const Icon(Icons.settings_rounded),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  ValueListenableBuilder(
                    valueListenable: AppUpdateService.instance.available,
                    builder: (context, update, _) {
                      if (update == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Material(
                          color: AppColors.accentLight.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.system_update_alt_rounded),
                            title: Text('Update v${update.version} tersedia'),
                            trailing: FilledButton(
                              onPressed: () => startAppUpdate(context),
                              child: const Text('Update'),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CampaignScreen()),
                    ),
                    icon: const Icon(Icons.campaign_outlined),
                    label: const Text('Campaign & Channel YT'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      foregroundColor: AppColors.primary,
                      side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _search(),
                          decoration: InputDecoration(
                            hintText: 'Kata kunci atau link...',
                            prefixIcon: const Icon(Icons.search),
                            filled: true,
                            fillColor: Colors.white,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: _pasteAndSearch,
                        tooltip: 'Tempel dari clipboard',
                        icon: const Icon(Icons.content_paste_go_rounded),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: _loading ? null : _search,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('Cari'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_loading)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/app_logo.png', width: 96, height: 96),
              const SizedBox(height: 16),
              Text(
                'Masukkan kata kunci judul video\natau tempel link YouTube',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final video = _results[index];
        return VideoTile(
          video: video,
          onTap: () => _openVideo(video),
        );
      },
    );
  }
}
