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
    final temps = <String>[];

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

      // Jangan ganti 720/1080 ke muxed 360p.
      final muxed = _youtube.muxedAt(manifest, option.height) ?? option.muxed;
      final videoOnly =
          _youtube.videoOnlyAt(manifest, option.height) ?? option.videoOnly;
      final audioOnly = _youtube.bestAudio(manifest) ?? option.audioOnly;

      final wantMuxed = option.isMuxed && muxed != null;
      final canAdaptive = videoOnly != null && audioOnly != null;
      final muxTooLow = option.height >= 720 &&
          muxed != null &&
          muxed.videoResolution.height < option.height - 80;
      final useMuxed =
          muxed != null && (wantMuxed || !canAdaptive) && !muxTooLow;

      if (useMuxed) {
        final ext = muxed.container.name;
        final rawPath = p.join(tempDir.path, 'raw_$stamp.$ext');
        temps.add(rawPath);
        final total = muxed.size.totalBytes;
        emit('Mengunduh ${muxed.qualityLabel}...', 0.05, total: total);
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
        emit('Menyiapkan file galeri...', 0.92);
        await _toGalleryMp4(rawPath, outputPath);
        return await _finish(
          outputPath,
          safeTitle,
          stamp,
          total,
          onProgress,
          emit,
        );
      }

      if (videoOnly == null || audioOnly == null) {
        throw Exception(
          'Stream ${option.label} tidak tersedia. Coba resolusi lain.',
        );
      }

      final videoPath = p.join(
        tempDir.path,
        'v_$stamp.${videoOnly.container.name}',
      );
      final audioPath = p.join(
        tempDir.path,
        'a_$stamp.${audioOnly.container.name}',
      );
      temps.addAll([videoPath, audioPath]);

      emit(
        'Mengunduh video ${option.label}...',
        0.05,
        total: videoOnly.size.totalBytes,
      );
      await YtStreamDownloader.download(
        videoOnly,
        videoPath,
        yt: yt,
        onBytes: (r, t) => emit(
          'Mengunduh video ${option.label}...',
          0.05 + 0.55 * (t <= 0 ? 0 : r / t),
          downloaded: r,
          total: t,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      final m2 = await _youtube.getManifest(videoId);
      final audio = _youtube.bestAudio(m2) ?? audioOnly;

      emit('Mengunduh audio...', 0.62, total: audio.size.totalBytes);
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
      );

      emit('Menggabungkan...', 0.92);
      await _merge(videoPath, audioPath, outputPath);

      final total = videoOnly.size.totalBytes + audio.size.totalBytes;
      return await _finish(
        outputPath,
        safeTitle,
        stamp,
        total,
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
    try {
      await Gal.putVideo(outputPath, album: 'YT Downloader');
    } on GalException catch (e) {
      if (e.type == GalExceptionType.notSupportedFormat) {
        // Remux ulang lalu coba sekali lagi.
        final fixed = '$outputPath.fixed.mp4';
        await _toGalleryMp4(outputPath, fixed);
        await Gal.putVideo(fixed, album: 'YT Downloader');
        await File(fixed).copy(outputPath);
        await _safeDelete(fixed);
      } else {
        rethrow;
      }
    }

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
        downloadedBytes: total,
        totalBytes: total <= 0 ? 1 : total,
        speedBytesPerSecond: 0,
        isDone: true,
      ),
    );
    return exportPath;
  }

  /// Pastikan file gallery-safe MP4 (faststart).
  Future<void> _toGalleryMp4(String input, String output) async {
    if (p.extension(input).toLowerCase() == '.mp4' && input != output) {
      var session = await FFmpegKit.execute(
        '-y -i "$input" -c copy -movflags +faststart "$output"',
      );
      var code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code) &&
          File(output).existsSync() &&
          File(output).lengthSync() > 2048) {
        return;
      }
    }

    var session = await FFmpegKit.execute(
      '-y -i "$input" -c:v copy -c:a aac -b:a 192k -movflags +faststart "$output"',
    );
    var code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code) &&
        File(output).existsSync() &&
        File(output).lengthSync() > 2048) {
      return;
    }

    // Last resort: copy raw if already named .mp4
    if (input != output &&
        File(input).existsSync() &&
        p.extension(input).toLowerCase() == '.mp4') {
      await File(input).copy(output);
      return;
    }

    final logs = await session.getAllLogsAsString();
    throw Exception(
      'Gagal siapkan MP4.\n${logs?.split('\n').take(6).join('\n') ?? ''}',
    );
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
