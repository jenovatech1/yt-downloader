import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/yt_dlp_service.dart';
import '../theme/app_theme.dart';
import '../utils/drive_link.dart';

/// Unduh file video Google Drive via yt-dlp (bukan YouTube).
class DriveDownloadScreen extends StatefulWidget {
  const DriveDownloadScreen({super.key, required this.url});

  final String url;

  @override
  State<DriveDownloadScreen> createState() => _DriveDownloadScreenState();
}

class _DriveDownloadScreenState extends State<DriveDownloadScreen> {
  bool _downloading = false;
  bool _done = false;
  double _progress = 0;
  String _phase = 'Siap unduh';
  String? _error;
  String? _outputPath;

  String get _fileId => driveFileId(widget.url) ?? '';
  String get _canonical =>
      normalizeDriveViewUrl(widget.url) ?? widget.url.trim();

  Future<void> _download() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _done = false;
      _error = null;
      _progress = 0;
      _phase = 'Menyiapkan yt-dlp…';
    });
    try {
      await YtDlpService.instance.ensureReady();
      final dir = await getTemporaryDirectory();
      final outDir = Directory(p.join(dir.path, 'drive_dl'));
      await outDir.create(recursive: true);
      final path = await YtDlpService.instance.downloadUrl(
        url: _canonical,
        outputDir: outDir.path,
        preferredId: _fileId.isEmpty ? null : _fileId,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p.progress01.clamp(0.0, 1.0);
            _phase = p.phase.isEmpty ? 'Mengunduh Drive…' : p.phase;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _outputPath = path;
        _done = true;
        _downloading = false;
        _progress = 1;
        _phase = 'Selesai';
      });
    } catch (e) {
      if (!mounted) return;
      final msg = '$e';
      final private = msg.toLowerCase().contains('private') ||
          msg.toLowerCase().contains('403') ||
          msg.toLowerCase().contains('login') ||
          msg.toLowerCase().contains('sign in');
      setState(() {
        _downloading = false;
        _error = private
            ? 'File Drive privat. Ubah akses ke siapa saja yang punya link.'
            : 'Gagal unduh Drive: $e';
      });
    }
  }

  Future<void> _saveGallery() async {
    final path = _outputPath;
    if (path == null) return;
    try {
      await Gal.putVideo(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tersimpan ke galeri')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal simpan: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Drive'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.accentLight.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.add_to_drive_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Sumber: Google Drive (bukan YouTube)',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('File ID', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(_fileId.isEmpty ? '—' : _fileId),
            const SizedBox(height: 12),
            Text('Link', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(_canonical, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              'Pastikan akses file: Siapa saja yang punya link. Video only.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            if (_downloading || _done) ...[
              LinearProgressIndicator(value: _done ? 1 : _progress),
              const SizedBox(height: 8),
              Text(_phase),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _downloading ? null : _download,
              icon: _downloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(_done ? 'Unduh ulang' : 'Unduh video'),
            ),
            if (_done && _outputPath != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _saveGallery,
                icon: const Icon(Icons.save_alt_rounded),
                label: const Text('Simpan ke galeri'),
              ),
              const SizedBox(height: 8),
              Text(
                p.basename(_outputPath!),
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
