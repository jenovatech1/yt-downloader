import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/hook_clip.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../widgets/youtube_style_player.dart';

class ClipPreviewScreen extends StatefulWidget {
  const ClipPreviewScreen({super.key, required this.clip});

  final HookClip clip;

  @override
  State<ClipPreviewScreen> createState() => _ClipPreviewScreenState();
}

class _ClipPreviewScreenState extends State<ClipPreviewScreen> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final file = File(widget.clip.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() => _error = 'File klip tidak ditemukan');
      return;
    }
    try {
      final c = VideoPlayerController.file(file);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memutar: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(clip.title ?? 'Klip ${clip.index + 1}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _buildPlayer(theme),
          ),
          const SizedBox(height: 16),
          Text(
            clip.title ?? 'Klip ${clip.index + 1}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Potongan asli YouTube '
            '${FormatUtils.duration(Duration(seconds: clip.startSec.round()))}'
            ' – ${FormatUtils.duration(Duration(seconds: clip.endSec.round()))}'
            '${clip.hookScore != null ? ' · skor ${clip.hookScore!.round()}' : ''}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer(ThemeData theme) {
    if (_error != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: const ColoredBox(
          color: Colors.black,
          child: Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          ),
        ),
      );
    }
    return YoutubeStylePlayer(controller: c);
  }
}
