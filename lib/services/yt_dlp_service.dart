import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:path/path.dart' as p;

/// yt-dlp (youtubedl-android) — stack sama Seal, tanpa ffmpeg_kit.
class YtDlpService {
  YtDlpService._();
  static final YtDlpService instance = YtDlpService._();

  final _dl = YoutubeDLFlutter.instance;
  bool _ready = false;
  bool _updating = false;

  Future<void> ensureReady() async {
    if (_ready) return;
    final init = await _dl.initialize(
      enableFFmpeg: true,
      enableAria2c: false,
    );
    if (!init.success) {
      throw Exception(init.errorMessage ?? 'Gagal init yt-dlp');
    }
    _ready = true;
    unawaited(_tryUpdate());
  }

  Future<void> _tryUpdate() async {
    if (_updating) return;
    _updating = true;
    try {
      await _dl.updateYoutubeDL(channel: UpdateChannel.stable);
    } catch (_) {
    } finally {
      _updating = false;
    }
  }

  static String formatForHeight(int height) {
    final h = height.clamp(144, 1080);
    return 'bestvideo[height<=$h][vcodec^=avc1]+bestaudio[ext=m4a]/'
        'bestvideo[height<=$h]+bestaudio/'
        'best[height<=$h]/best';
  }

  Map<String?, String?> get _baseArgs => {
        '--extractor-args':
            'youtube:player_client=android_vr,web_embedded,ios',
        '--merge-output-format': 'mp4',
        '--no-mtime': '',
        '--retries': '10',
        '--fragment-retries': '10',
        '--no-playlist': '',
      };

  Future<String> downloadVideo({
    required String videoId,
    required int height,
    required String outputDir,
    required void Function(double progress01, String phase) onProgress,
    double? sectionStart,
    double? sectionEnd,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId =
        'v_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final custom = Map<String?, String?>.from(_baseArgs);
    if (sectionStart != null &&
        sectionEnd != null &&
        sectionEnd > sectionStart) {
      custom['--download-sections'] =
          '*${sectionStart.toStringAsFixed(3)}-${sectionEnd.toStringAsFixed(3)}';
      custom['--force-keyframes-at-cuts'] = '';
    }

    final sub = _dl.onProgress.listen((p) {
      if (p.processId != processId) return;
      onProgress((p.progress / 100).clamp(0.0, 0.99), 'Mengunduh (yt-dlp)...');
    });

    try {
      onProgress(0.02, 'Menyiapkan yt-dlp...');
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: sectionStart != null
              ? '%(id)s_clip_%(autonumber)s.%(ext)s'
              : '%(id)s_%(height)sp.%(ext)s',
          format: formatForHeight(height),
          noPlaylist: true,
          processId: processId,
          customOptions: custom,
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

  Future<String> downloadAudio({
    required String videoId,
    required String outputDir,
    required void Function(double progress01, String phase) onProgress,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId = 'a_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final sub = _dl.onProgress.listen((p) {
      if (p.processId != processId) return;
      onProgress((p.progress / 100).clamp(0.0, 0.99), 'Mengunduh audio...');
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
            ..._baseArgs,
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
      if (await Directory(preferred).exists()) dir = preferred;
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
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );

    for (final f in files) {
      final name = p.basename(f.path).toLowerCase();
      final ext = p.extension(name);
      if (audioOnly) {
        if ({'.m4a', '.mp3', '.opus', '.webm', '.ogg'}.contains(ext) &&
            await f.length() > 1024) {
          return f.path;
        }
      } else if ({'.mp4', '.mkv', '.webm', '.mov'}.contains(ext) &&
          await f.length() > 2048) {
        return f.path;
      }
    }
    for (final f in files) {
      if (await f.length() > 2048) return f.path;
    }
    throw Exception('File hasil yt-dlp kosong');
  }
}
