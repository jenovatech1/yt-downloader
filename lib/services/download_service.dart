import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';
import '../models/download_progress.dart';
import 'chunked_stream_downloader.dart';
import 'youtube_service.dart';

typedef DetailedProgressCallback = void Function(DownloadProgress progress);

class DownloadService {
  DownloadService(this._youtube);

  final YoutubeService _youtube;

  Future<String?> runJob({
    required Video video,
    required DownloadOption option,
    required DetailedProgressCallback onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final safeTitle = _sanitize(video.title);
    final outputPath = p.join(tempDir.path, '${safeTitle}_$stamp.mp4');
    final videoId = video.id.value;
    final yt = _youtube.client;

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
      emit('Menyiapkan...', 0.02);

      final manifest = await _youtube.getManifest(videoId);
      final muxedExact = _youtube.muxedAt(manifest, option.height);
      final muxedBest = manifest.muxed.isEmpty
          ? null
          : (manifest.muxed.toList()
                ..sort(
                  (a, b) => b.videoResolution.height
                      .compareTo(a.videoResolution.height),
                ))
              .first;
      final videoOnly = _youtube.videoOnlyAt(manifest, option.height);
      final audioOnly = _youtube.bestAudio(manifest);

      // Muxed lebih stabil (sering tidak throttle). Pakai kalau cocok / aman.
      final useMuxed = muxedExact ??
          (option.height <= 720 ? muxedBest : null) ??
          (videoOnly == null || audioOnly == null ? muxedBest : null);

      if (useMuxed != null &&
          (option.isMuxed ||
              option.height <= 720 ||
              videoOnly == null ||
              audioOnly == null ||
              useMuxed.videoResolution.height >= option.height - 200)) {
        final total = useMuxed.size.totalBytes;
        emit(
          'Mengunduh ${useMuxed.qualityLabel}...',
          0.05,
          total: total,
        );
        await ChunkedStreamDownloader.download(
          useMuxed,
          outputPath,
          ytForRefresh: yt,
          onBytes: (r, t) => emit(
            'Mengunduh video...',
            0.05 + 0.90 * (t <= 0 ? 0 : r / t),
            downloaded: r,
            total: t,
          ),
        );
      } else if (videoOnly != null && audioOnly != null) {
        final videoPath = p.join(
          tempDir.path,
          'v_$stamp.${videoOnly.container.name}',
        );
        final audioPath = p.join(
          tempDir.path,
          'a_$stamp.${audioOnly.container.name}',
        );

        emit('Mengunduh video...', 0.05, total: videoOnly.size.totalBytes);
        await ChunkedStreamDownloader.download(
          videoOnly,
          videoPath,
          ytForRefresh: yt,
          onBytes: (r, t) => emit(
            'Mengunduh video...',
            0.05 + 0.55 * (t <= 0 ? 0 : r / t),
            downloaded: r,
            total: t,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 600));
        final m2 = await _youtube.getManifest(videoId);
        final audio = _youtube.bestAudio(m2) ?? audioOnly;

        emit('Mengunduh audio...', 0.62, total: audio.size.totalBytes);
        await ChunkedStreamDownloader.download(
          audio,
          audioPath,
          ytForRefresh: yt,
          onBytes: (r, t) => emit(
            'Mengunduh audio...',
            0.62 + 0.28 * (t <= 0 ? 0 : r / t),
            downloaded: r,
            total: t,
          ),
        );

        emit('Menggabungkan...', 0.92);
        await _merge(videoPath, audioPath, outputPath);
        await _safeDelete(videoPath);
        await _safeDelete(audioPath);
      } else {
        throw Exception('Tidak ada stream yang bisa diunduh.');
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
          downloadedBytes: 1,
          totalBytes: 1,
          speedBytesPerSecond: 0,
          isDone: true,
        ),
      );
      return exportPath;
    } finally {
      await _safeDelete(outputPath);
    }
  }

  Future<void> _merge(
    String videoPath,
    String audioPath,
    String outputPath,
  ) async {
    var session = await FFmpegKit.execute(
      '-y -i "$videoPath" -i "$audioPath" -c:v copy -c:a copy -movflags +faststart "$outputPath"',
    );
    var code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code) || !File(outputPath).existsSync()) {
      session = await FFmpegKit.execute(
        '-y -i "$videoPath" -i "$audioPath" -c:v copy -c:a aac -b:a 192k -movflags +faststart "$outputPath"',
      );
      code = await session.getReturnCode();
    }
    if (!ReturnCode.isSuccess(code) || !File(outputPath).existsSync()) {
      final logs = await session.getAllLogsAsString();
      throw Exception(
        'Gagal menggabungkan.\n${logs?.split('\n').take(6).join('\n') ?? ''}',
      );
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

  Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
