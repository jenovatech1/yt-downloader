import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_muxer_2025/youtube_muxer_2025.dart' as muxer;

import '../models/download_option.dart';
import '../models/download_progress.dart';

typedef DetailedProgressCallback = void Function(DownloadProgress progress);

/// Download via NewPipe (native) + multi-connection — bypass throttle YouTube.
/// youtube_explode hang di Android; jangan dipakai untuk unduh byte.
class DownloadService {
  DownloadService();

  final _downloader = muxer.YoutubeDownloader();

  Future<String?> runJob({
    required Video video,
    required DownloadOption option,
    required DetailedProgressCallback onProgress,
  }) async {
    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';
    final totalBytes = option.totalBytes <= 0 ? 1 : option.totalBytes;
    final safeTitle = _sanitize(video.title);
    final stamp = DateTime.now().millisecondsSinceEpoch;

    void emit(
      String phase,
      double progress, {
      int downloaded = 0,
      bool force = true,
    }) {
      onProgress(
        DownloadProgress(
          phase: phase,
          progress: progress.clamp(0.0, 0.99),
          downloadedBytes: downloaded.clamp(0, totalBytes),
          totalBytes: totalBytes,
          speedBytesPerSecond: 0,
        ),
      );
    }

    emit('Menyiapkan (NewPipe)...', 0.02);

    final qualities = await _downloader.getQualities(youtubeUrl);
    final videoQs = qualities.where((q) => q.fps > 0).toList();
    if (videoQs.isEmpty) {
      throw Exception('Tidak ada stream video (NewPipe).');
    }

    final selected = _pickQuality(videoQs, option.height);
    emit('Mengunduh ${selected.quality}...', 0.05);

    String? outputPath;
    await for (final prog in _downloader.downloadVideo(selected, youtubeUrl)) {
      final pct = prog.progress.clamp(0.0, 1.0);
      emit(
        prog.status.isNotEmpty ? prog.status : 'Mengunduh...',
        0.05 + 0.90 * pct,
        downloaded: (totalBytes * pct).round(),
      );
      if (prog.outputPath != null && prog.outputPath!.isNotEmpty) {
        outputPath = prog.outputPath;
      }
    }

    if (outputPath == null || !File(outputPath).existsSync()) {
      throw Exception('Download selesai tapi file tidak ditemukan.');
    }

    emit('Menyimpan ke galeri...', 0.96);
    await Gal.putVideo(outputPath, album: 'YT Downloader');

    final docs = await getApplicationDocumentsDirectory();
    final exportDir = Directory(p.join(docs.path, 'exports'));
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    final exportPath = p.join(exportDir.path, '${safeTitle}_$stamp.mp4');
    await File(outputPath).copy(exportPath);

    onProgress(
      DownloadProgress(
        phase: 'Selesai',
        progress: 1,
        downloadedBytes: totalBytes,
        totalBytes: totalBytes,
        speedBytesPerSecond: 0,
        isDone: true,
      ),
    );
    return exportPath;
  }

  muxer.VideoQuality _pickQuality(List<muxer.VideoQuality> list, int height) {
    int heightOf(muxer.VideoQuality q) {
      final m = RegExp(r'(\d{3,4})').firstMatch(q.quality);
      return int.tryParse(m?.group(1) ?? '') ?? 0;
    }

    final exact = list.where((q) => heightOf(q) == height).toList();
    if (exact.isNotEmpty) {
      exact.sort((a, b) => b.bitrate.compareTo(a.bitrate));
      return exact.first;
    }

    // Terdekat di bawah height, atau terdekat overall.
    final below = list.where((q) => heightOf(q) <= height && heightOf(q) > 0).toList()
      ..sort((a, b) => heightOf(b).compareTo(heightOf(a)));
    if (below.isNotEmpty) return below.first;

    final sorted = [...list]..sort((a, b) => heightOf(b).compareTo(heightOf(a)));
    return sorted.first;
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
