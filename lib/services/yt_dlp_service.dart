import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:path/path.dart' as p;

/// Wrapper yt-dlp (youtubedl-android) — engine yang sama dipakai Seal.
class YtDlpService {
  YtDlpService._();
  static final YtDlpService instance = YtDlpService._();

  final _dl = YoutubeDLFlutter.instance;
  bool _ready = false;
  bool _updating = false;

  bool get isReady => _ready;

  Future<void> ensureReady() async {
    if (_ready) return;
    final init = await _dl.initialize(
      enableFFmpeg: true,
      enableAria2c: true,
    );
    if (!init.success) {
      throw Exception(init.errorMessage ?? 'Gagal init yt-dlp');
    }
    _ready = true;
    // Update binary di background (yt-dlp 2026.x).
    unawaited(_tryUpdate());
  }

  Future<void> _tryUpdate() async {
    if (_updating) return;
    _updating = true;
    try {
      await _dl.updateYoutubeDL(channel: UpdateChannel.stable);
    } catch (_) {
      // Offline / rate-limit — pakai binary bawaan.
    } finally {
      _updating = false;
    }
  }

  /// Format string ala yt-dlp untuk resolusi target (prefer H.264 + m4a).
  static String formatForHeight(int height) {
    final h = height.clamp(144, 1080);
    return 'bestvideo[height<=$h][vcodec^=avc1]+bestaudio[ext=m4a]/'
        'bestvideo[height<=$h]+bestaudio/'
        'best[height<=$h]/best';
  }

  Map<String?, String?> get _ytArgs => {
        // Sesuai rekomendasi yt-dlp 2026: android_vr tanpa PO token.
        '--extractor-args':
            'youtube:player_client=android_vr,web_embedded,ios',
        '--merge-output-format': 'mp4',
        '--no-mtime': '',
        '--retries': '10',
        '--fragment-retries': '10',
        '--no-playlist': '',
      };

  /// Unduh video → file MP4 di [outputDir]. Return path file hasil.
  Future<String> downloadVideo({
    required String videoId,
    required int height,
    required String outputDir,
    required void Function(double progress01, String phase) onProgress,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId =
        'vid_${videoId}_${height}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final sub = _dl.onProgress.listen((p) {
      if (p.processId != processId) return;
      final pct = (p.progress / 100).clamp(0.0, 0.99);
      onProgress(pct, 'Mengunduh (yt-dlp)...');
    });

    try {
      onProgress(0.02, 'Menyiapkan yt-dlp...');
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_%(height)s.%(ext)s',
          format: formatForHeight(height),
          noPlaylist: true,
          processId: processId,
          customOptions: _ytArgs,
        ),
      );

      if (result.status != OperationStatus.success) {
        throw Exception(result.errorMessage ?? 'yt-dlp gagal unduh video');
      }

      final out = await _findOutput(
        outputDir,
        preferred: result.outputPath,
        videoId: videoId,
      );
      onProgress(1, 'Selesai unduh');
      return out;
    } finally {
      await sub.cancel();
    }
  }

  /// Unduh audio saja (untuk transkrip Get Clip).
  Future<String> downloadAudio({
    required String videoId,
    required String outputDir,
    required void Function(double progress01, String phase) onProgress,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId = 'aud_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final sub = _dl.onProgress.listen((p) {
      if (p.processId != processId) return;
      final pct = (p.progress / 100).clamp(0.0, 0.99);
      onProgress(pct, 'Mengunduh audio (yt-dlp)...');
    });

    try {
      onProgress(0.02, 'Menyiapkan audio...');
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_audio.%(ext)s',
          format: 'bestaudio/best',
          extractAudio: true,
          audioFormat: 'm4a',
          audioQuality: 5,
          noPlaylist: true,
          processId: processId,
          customOptions: {
            ..._ytArgs,
            '--extract-audio': '',
            '--audio-format': 'm4a',
          },
        ),
      );

      if (result.status != OperationStatus.success) {
        throw Exception(result.errorMessage ?? 'yt-dlp gagal unduh audio');
      }

      final out = await _findOutput(
        outputDir,
        preferred: result.outputPath,
        videoId: videoId,
        audioOnly: true,
      );
      onProgress(1, 'Audio siap');
      return out;
    } finally {
      await sub.cancel();
    }
  }

  Future<String> _findOutput(
    String dir, {
    String? preferred,
    required String videoId,
    bool audioOnly = false,
  }) async {
    if (preferred != null && preferred.isNotEmpty) {
      final f = File(preferred);
      if (await f.exists() && await f.length() > 2048) return preferred;
      // Kadang outputPath = folder.
      if (await Directory(preferred).exists()) {
        dir = preferred;
      }
    }

    final folder = Directory(dir);
    if (!await folder.exists()) {
      throw Exception('Output yt-dlp tidak ditemukan');
    }

    final files = await folder
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    for (final f in files) {
      final name = p.basename(f.path).toLowerCase();
      if (!name.contains(videoId.toLowerCase()) && files.length > 1) continue;
      final ext = p.extension(name);
      if (audioOnly) {
        if (const {'.m4a', '.mp3', '.opus', '.webm', '.ogg'}.contains(ext)) {
          if (await f.length() > 1024) return f.path;
        }
      } else {
        if (const {'.mp4', '.mkv', '.webm', '.mov'}.contains(ext)) {
          if (await f.length() > 2048) return f.path;
        }
      }
    }

    // Fallback: file terbaru yang cukup besar.
    for (final f in files) {
      if (await f.length() > 2048) return f.path;
    }
    throw Exception('File hasil yt-dlp kosong');
  }
}
