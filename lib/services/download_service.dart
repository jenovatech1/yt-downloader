import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';
import '../models/download_progress.dart';
import 'yt_dlp_service.dart';

typedef DetailedProgressCallback = void Function(DownloadProgress progress);

/// Download via yt-dlp saja (merge FFmpeg internal yt-dlp).
class DownloadService {
  DownloadService();

  Future<String?> runJob({
    required Video video,
    required DownloadOption option,
    required DetailedProgressCallback onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final safeTitle = _sanitize(video.title);
    final workDir = Directory(p.join(tempDir.path, 'ytdlp_$stamp'));
    await workDir.create(recursive: true);

    void emit(String phase, double progress, {int downloaded = 0, int total = 0}) {
      onProgress(
        DownloadProgress(
          phase: phase,
          progress: progress.clamp(0.0, 0.99),
          downloadedBytes: downloaded,
          totalBytes: total <= 0 ? 1 : total,
          speedBytesPerSecond: 0,
        ),
      );
    }

    try {
      emit('Menyiapkan ${option.label} (yt-dlp)...', 0.02);
      final filePath = await YtDlpService.instance.downloadVideo(
        videoId: video.id.value,
        height: option.height,
        outputDir: workDir.path,
        onProgress: (pct, phase) => emit(phase, 0.05 + 0.88 * pct),
      );

      var galleryPath = filePath;
      if (p.extension(filePath).toLowerCase() != '.mp4') {
        galleryPath = p.join(workDir.path, 'out_$stamp.mp4');
        await File(filePath).copy(galleryPath);
      }

      emit('Menyimpan ke galeri...', 0.96);
      if (!File(galleryPath).existsSync() ||
          File(galleryPath).lengthSync() < 2048) {
        throw Exception('File hasil kosong');
      }
      await Gal.putVideo(galleryPath, album: 'YT Downloader');

      final docs = await getApplicationDocumentsDirectory();
      final exportDir = Directory(p.join(docs.path, 'exports'));
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      final exportPath = p.join(exportDir.path, '${safeTitle}_$stamp.mp4');
      await File(galleryPath).copy(exportPath);

      onProgress(
        DownloadProgress(
          phase: 'Selesai',
          progress: 1,
          downloadedBytes: option.totalBytes,
          totalBytes: option.totalBytes <= 0 ? 1 : option.totalBytes,
          speedBytesPerSecond: 0,
          isDone: true,
        ),
      );
      return exportPath;
    } finally {
      try {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _sanitize(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return 'youtube_video';
    return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
  }
}
