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
import 'yt_stream_downloader.dart';

typedef DetailedProgressCallback = void Function(DownloadProgress progress);

/// HD policy 23 Agu 2026:
/// 1) HLS iOS segments
/// 2) android_sdkless progressive (Range header)
/// 3) muxed ≤360
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
    final temps = <String>[];
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
      emit('Menyiapkan ${option.label}...', 0.02);
      final manifest = await _youtube.getManifest(videoId);

      final hlsVideo = option.hlsVideo ??
          _youtube.hlsVideoAt(manifest, option.height) ??
          _youtube.hlsVideoClosest(manifest, option.height);
      final hlsAudio = option.hlsAudio ?? _youtube.hlsAudio(manifest);
      final videoOnly =
          option.videoOnly ?? _youtube.videoOnlyAt(manifest, option.height);
      final audioOnly = option.audioOnly ?? _youtube.bestAudio(manifest);
      final muxed = option.muxed ?? _youtube.muxedAt(manifest, option.height);

      // --- A: HLS HD ---
      if (hlsVideo != null && hlsAudio != null && !option.isMuxed) {
        try {
          final videoPath = p.join(tempDir.path, 'hv_$stamp.ts');
          final audioPath = p.join(tempDir.path, 'ha_$stamp.ts');
          temps.addAll([videoPath, audioPath]);
          emit('Mengunduh video HLS ${option.label}...', 0.05);
          await YtStreamDownloader.download(
            hlsVideo,
            videoPath,
            yt: yt,
            onBytes: (r, t) => emit(
              'Mengunduh video HLS...',
              0.05 + 0.55 * (t <= 0 ? 0 : r / t),
              downloaded: r,
              total: t,
            ),
          );
          emit('Mengunduh audio HLS...', 0.62);
          await YtStreamDownloader.download(
            hlsAudio,
            audioPath,
            yt: yt,
            onBytes: (r, t) => emit(
              'Mengunduh audio HLS...',
              0.62 + 0.28 * (t <= 0 ? 0 : r / t),
              downloaded: r,
              total: t,
            ),
          );
          emit('Menggabungkan...', 0.92);
          await _merge(videoPath, audioPath, outputPath);
          return await _finish(
            outputPath,
            safeTitle,
            stamp,
            hlsVideo.size.totalBytes + hlsAudio.size.totalBytes,
            onProgress,
            emit,
          );
        } catch (_) {
          // lanjut adaptive / muxed
        }
      }

      // --- B: adaptive progressive HD (android_sdkless, Range header) ---
      if (!option.isMuxed && option.height >= 480) {
        StreamManifest andManifest;
        try {
          andManifest = await _youtube.getAndroidManifest(videoId);
        } catch (_) {
          andManifest = manifest;
        }
        final vProg = _youtube.videoOnlyAt(andManifest, option.height) ??
            videoOnly;
        final aProg = _youtube.bestAudio(andManifest) ?? audioOnly;

        if (vProg != null && aProg != null) {
          final videoPath =
              p.join(tempDir.path, 'v_$stamp.${vProg.container.name}');
          final audioPath =
              p.join(tempDir.path, 'a_$stamp.${aProg.container.name}');
          temps.addAll([videoPath, audioPath]);

          emit('Mengunduh video ${option.label}...', 0.05);
          await YtStreamDownloader.download(
            vProg,
            videoPath,
            yt: yt,
            onBytes: (r, t) => emit(
              'Mengunduh video...',
              0.05 + 0.55 * (t <= 0 ? 0 : r / t),
              downloaded: r,
              total: t,
            ),
            refreshStream: () async {
              final m = await _youtube.getAndroidManifest(videoId);
              return _youtube.videoOnlyAt(m, option.height) ?? vProg;
            },
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final m2 = await _youtube.getAndroidManifest(videoId);
          final audio = _youtube.bestAudio(m2) ?? aProg;
          emit('Mengunduh audio...', 0.62);
          await YtStreamDownloader.download(
            audio,
            audioPath,
            yt: yt,
            onBytes: (r, t) => emit(
              'Mengunduh audio...',
              0.62 + 0.28 * (t <= 0 ? 0 : r / t),
              downloaded: r,
              total: t,
            ),
            refreshStream: () async {
              final m = await _youtube.getAndroidManifest(videoId);
              return _youtube.bestAudio(m) ?? audio;
            },
          );
          emit('Menggabungkan...', 0.92);
          await _merge(videoPath, audioPath, outputPath);
          return await _finish(
            outputPath,
            safeTitle,
            stamp,
            vProg.size.totalBytes + audio.size.totalBytes,
            onProgress,
            emit,
          );
        }
      }

      // --- C: muxed ≤360 ---
      if (muxed == null) {
        throw Exception(
          'Stream ${option.label} tidak tersedia. Coba kualitas lain.',
        );
      }
      final rawPath =
          p.join(tempDir.path, 'raw_$stamp.${muxed.container.name}');
      temps.add(rawPath);
      emit('Mengunduh ${muxed.qualityLabel}...', 0.05);
      await YtStreamDownloader.download(
        muxed,
        rawPath,
        yt: yt,
        onBytes: (r, t) => emit(
          'Mengunduh ${muxed.qualityLabel}...',
          0.05 + 0.85 * (t <= 0 ? 0 : r / t),
          downloaded: r,
          total: t,
        ),
      );
      emit('Menyiapkan file...', 0.92);
      await _toMp4(rawPath, outputPath);
      return await _finish(
        outputPath,
        safeTitle,
        stamp,
        muxed.size.totalBytes,
        onProgress,
        emit,
      );
    } finally {
      for (final path in temps) {
        await _safeDelete(path);
      }
      await _safeDelete(outputPath);
    }
  }

  Future<String> _finish(
    String outputPath,
    String safeTitle,
    int stamp,
    int total,
    DetailedProgressCallback onProgress,
    void Function(String, double, {int downloaded, int total}) emit,
  ) async {
    if (!File(outputPath).existsSync() || File(outputPath).lengthSync() < 2048) {
      throw Exception('File hasil kosong / rusak.');
    }
    emit('Menyimpan ke galeri...', 0.96);
    await Gal.putVideo(outputPath, album: 'YT Downloader');

    final docs = await getApplicationDocumentsDirectory();
    final exportDir = Directory(p.join(docs.path, 'exports'));
    if (!await exportDir.exists()) await exportDir.create(recursive: true);
    final exportPath = p.join(exportDir.path, '${safeTitle}_$stamp.mp4');
    await File(outputPath).copy(exportPath);

    onProgress(
      DownloadProgress(
        phase: 'Selesai',
        progress: 1,
        downloadedBytes: total,
        totalBytes: total <= 0 ? 1 : total,
        speedBytesPerSecond: 0,
        isDone: true,
      ),
    );
    return exportPath;
  }

  Future<void> _toMp4(String input, String output) async {
    final session = await FFmpegKit.execute(
      '-y -i "$input" -c copy -movflags +faststart "$output"',
    );
    final code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code) &&
        File(output).existsSync() &&
        File(output).lengthSync() > 2048) {
      return;
    }
    if (input != output) await File(input).copy(output);
  }

  Future<void> _merge(String videoPath, String audioPath, String outputPath) async {
    var session = await FFmpegKit.execute(
      '-y -i "$videoPath" -i "$audioPath" -c:v copy -c:a aac -b:a 192k -movflags +faststart "$outputPath"',
    );
    var code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code) || !File(outputPath).existsSync()) {
      session = await FFmpegKit.execute(
        '-y -i "$videoPath" -i "$audioPath" -c copy -movflags +faststart "$outputPath"',
      );
      code = await session.getReturnCode();
    }
    if (!ReturnCode.isSuccess(code) ||
        !File(outputPath).existsSync() ||
        File(outputPath).lengthSync() < 2048) {
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
