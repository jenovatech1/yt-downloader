import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';
import '../models/download_progress.dart';
import 'stream_downloader.dart';
import 'youtube_service.dart';

typedef DetailedProgressCallback = void Function(DownloadProgress progress);

class DownloadService {
  DownloadService(this._youtube);

  final YoutubeService _youtube;

  static const _emitIntervalMs = 200;
  static const _speedWindowMs = 400;

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

    // Manifest fresh. Docs library: android client sering tolak unduh
    // >1 stream dari manifest yang sama → video & audio pakai manifest terpisah.
    final job = await _youtube.resolveDownloadOption(videoId, option.height) ??
        option;
    final totalBytes = job.totalBytes <= 0 ? 1 : job.totalBytes;
    final yt = _youtube.client;

    var lastSpeedTick = DateTime.now();
    var lastSpeedBytes = 0;
    var speed = 0.0;
    var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

    void emit(
      String phase,
      int downloaded, {
      double? progressOverride,
      bool force = false,
    }) {
      final now = DateTime.now();
      final speedElapsed = now.difference(lastSpeedTick).inMilliseconds;
      if (speedElapsed >= _speedWindowMs) {
        final delta = downloaded - lastSpeedBytes;
        if (delta >= 0) {
          speed = (delta * 1000) / speedElapsed;
        }
        lastSpeedTick = now;
        lastSpeedBytes = downloaded;
      }

      if (!force &&
          now.difference(lastEmitAt).inMilliseconds < _emitIntervalMs) {
        return;
      }
      lastEmitAt = now;

      onProgress(
        DownloadProgress(
          phase: phase,
          progress: (progressOverride ?? (downloaded / totalBytes))
              .clamp(0.0, 0.95),
          downloadedBytes: downloaded.clamp(0, totalBytes),
          totalBytes: totalBytes,
          speedBytesPerSecond: speed,
        ),
      );
    }

    try {
      if (job.isMuxed && job.muxed != null) {
        emit('Mengunduh video', 0, force: true);
        await StreamDownloader.download(
          yt,
          job.muxed!,
          outputPath,
          onBytes: (received, _) => emit('Mengunduh video', received),
        );
        emit('Mengunduh video', totalBytes, force: true);
      } else {
        // Ambil video dari manifest #1
        final manifestVideo = await _youtube.getManifest(videoId);
        final videoOnly = _youtube.videoOnlyAt(manifestVideo, job.height) ??
            job.videoOnly;
        if (videoOnly == null) {
          throw Exception('Stream video ${job.height}p tidak tersedia');
        }

        final videoPath = p.join(
          tempDir.path,
          'v_$stamp.${videoOnly.container.name}',
        );

        emit('Mengunduh video', 0, force: true);
        var videoReceived = 0;
        await StreamDownloader.download(
          yt,
          videoOnly,
          videoPath,
          onBytes: (received, total) {
            videoReceived = received;
            final t = total <= 0 ? 1 : total;
            emit(
              'Mengunduh video',
              received,
              progressOverride: (0.72 * (received / t)).clamp(0, 0.72),
            );
          },
        );

        // Manifest #2 khusus audio (workaround restriksi YouTube).
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final manifestAudio = await _youtube.getManifest(videoId);
        final audioOnly =
            _youtube.bestAudio(manifestAudio) ?? job.audioOnly;
        if (audioOnly == null) {
          throw Exception('Stream audio tidak tersedia');
        }

        final audioPath = p.join(
          tempDir.path,
          'a_$stamp.${audioOnly.container.name}',
        );

        emit('Mengunduh audio', videoReceived, force: true);
        await StreamDownloader.download(
          yt,
          audioOnly,
          audioPath,
          onBytes: (received, total) {
            final t = total <= 0 ? 1 : total;
            emit(
              'Mengunduh audio',
              videoReceived + received,
              progressOverride: (0.72 + 0.23 * (received / t)).clamp(0.72, 0.95),
            );
          },
        );

        emit('Menggabungkan', totalBytes, progressOverride: 0.96, force: true);
        await _merge(videoPath, audioPath, outputPath);
        emit('Menggabungkan', totalBytes, progressOverride: 0.98, force: true);

        await _safeDelete(videoPath);
        await _safeDelete(audioPath);
      }

      emit('Menyimpan ke galeri', totalBytes, progressOverride: 0.99, force: true);
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
        'Gagal menggabungkan video.\n${logs?.split('\n').take(8).join('\n') ?? ''}',
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
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
