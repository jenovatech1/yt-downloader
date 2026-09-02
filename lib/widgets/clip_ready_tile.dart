import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/hook_clip.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';

/// Kartu klip yang bisa langsung diputar (inline).
class ClipReadyTile extends StatefulWidget {
  const ClipReadyTile({super.key, required this.clip});

  final HookClip clip;

  @override
  State<ClipReadyTile> createState() => _ClipReadyTileState();
}

class _ClipReadyTileState extends State<ClipReadyTile> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(ClipReadyTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.filePath != widget.clip.filePath) {
      _controller?.dispose();
      _controller = null;
      _loading = true;
      _error = null;
      _init();
    }
  }

  Future<void> _init() async {
    final file = File(widget.clip.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'File belum siap';
      });
      return;
    }
    try {
      final c = VideoPlayerController.file(file);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Gagal memutar';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final theme = Theme.of(context);
    final c = _controller;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _buildPlayer(theme, c),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                  child: Text(
                    '${clip.index + 1}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        clip.title ?? 'Klip ${clip.index + 1}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${FormatUtils.duration(Duration(seconds: clip.startSec.round()))}'
                        ' – ${FormatUtils.duration(Duration(seconds: clip.endSec.round()))}'
                        '${clip.hookScore != null ? ' · skor ${clip.hookScore!.round()}' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: c != null && c.value.isInitialized ? _togglePlay : null,
                  icon: Icon(
                    c != null && c.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer(ThemeData theme, VideoPlayerController? c) {
    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(_error!, style: const TextStyle(color: Colors.white70)),
        ),
      );
    }
    if (_loading || c == null || !c.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );
    }
    return GestureDetector(
      onTap: _togglePlay,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(c),
          if (!c.value.isPlaying)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(32),
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 36),
            ),
        ],
      ),
    );
  }
}
