import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';
import '../models/download_progress.dart';
import 'youtube_service.dart';

typedef DetailedProgressCallback = void Function(DownloadProgress progress);

class DownloadService {
  DownloadService(this._youtube);

  final YoutubeService _youtube;

  static const _emitIntervalMs = 500;
  static const _speedWindowMs = 500;

  Future<String?> runJob({
    required Video video,
    required DownloadOption option,
    required DetailedProgressCallback onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final safeTitle = _sanitize(video.title);
    final outputPath = p.join(tempDir.path, '${safeTitle}_$stamp.mp4');
    final totalBytes = option.totalBytes <= 0 ? 1 : option.totalBytes;

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

      final progress =
          progressOverride ?? (downloaded / totalBytes).clamp(0.0, 0.95);

      onProgress(
        DownloadProgress(
          phase: phase,
          progress: progress,
          downloadedBytes: downloaded.clamp(0, totalBytes),
          totalBytes: totalBytes,
          speedBytesPerSecond: speed,
        ),
      );
    }

    try {
      if (option.isMuxed && option.muxed != null) {
        emit('Mengunduh video', 0, force: true);
        await _downloadStream(
          option.muxed!,
          outputPath,
          onBytes: (received) => emit('Mengunduh video', received),
        );
        emit('Mengunduh video', totalBytes, force: true);
      } else {
        if (option.videoOnly == null || option.audioOnly == null) {
          throw Exception('Stream video/audio tidak tersedia');
        }

        final videoPath = p.join(
          tempDir.path,
          'v_$stamp.${option.videoOnly!.container.name}',
        );
        final audioPath = p.join(
          tempDir.path,
          'a_$stamp.${option.audioOnly!.container.name}',
        );

        var videoReceived = 0;
        var audioReceived = 0;

        emit('Mengunduh video + audio', 0, force: true);

        // Parallel download: hampir 2x lebih cepat daripada sekuensial.
        await Future.wait([
          _downloadStream(
            option.videoOnly!,
            videoPath,
            onBytes: (received) {
              videoReceived = received;
              emit('Mengunduh video + audio', videoReceived + audioReceived);
            },
          ),
          _downloadStream(
            option.audioOnly!,
            audioPath,
            onBytes: (received) {
              audioReceived = received;
              emit('Mengunduh video + audio', videoReceived + audioReceived);
            },
          ),
        ]);

        emit(
          'Menggabungkan',
          totalBytes,
          progressOverride: 0.96,
          force: true,
        );
        await _merge(videoPath, audioPath, outputPath);
        emit(
          'Menggabungkan',
          totalBytes,
          progressOverride: 0.98,
          force: true,
        );

        await _safeDelete(videoPath);
        await _safeDelete(audioPath);
      }

      emit(
        'Menyimpan ke galeri',
        totalBytes,
        progressOverride: 0.99,
        force: true,
      );
      await Gal.putVideo(outputPath, album: 'YT Downloader');

      // Salinan untuk "Buka di Klippod" (download stream tetap sama).
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

  Future<void> _downloadStream(
    StreamInfo info,
    String path, {
    required void Function(int received) onBytes,
  }) async {
    var received = 0;
    var pendingEmit = 0;
    await _youtube.downloadToFile(
      info,
      path,
      onBytes: (got, _) {
        received = got;
        pendingEmit += 256 * 1024;
        if (pendingEmit >= 1024 * 1024 ||
            (info.size.totalBytes > 0 && received >= info.size.totalBytes)) {
          pendingEmit = 0;
          onBytes(received);
        }
      },
    );
    onBytes(received);
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
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
