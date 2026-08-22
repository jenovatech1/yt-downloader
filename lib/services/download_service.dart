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

      // PENTING: jangan ganti 720/1080 ke muxed 360p.
      // Muxed HANYA kalau user pilih opsi muxed, atau adaptive tidak ada.
      final muxed = _youtube.muxedAt(manifest, option.height) ?? option.muxed;
      final videoOnly =
          _youtube.videoOnlyAt(manifest, option.height) ?? option.videoOnly;
      final audioOnly = _youtube.bestAudio(manifest) ?? option.audioOnly;

      final wantMuxed = option.isMuxed && muxed != null;
      final canAdaptive = videoOnly != null && audioOnly != null;
      final useMuxed = wantMuxed || (!canAdaptive && muxed != null);

      if (useMuxed && muxed != null) {
        // Pastikan resolusi muxed tidak jauh di bawah pilihan user.
        if (option.height >= 720 &&
            muxed.videoResolution.height < option.height - 80 &&
            canAdaptive) {
          // Abaikan muxed rendah — pakai adaptive.
        } else {
          final total = muxed.size.totalBytes;
          emit('Mengunduh ${muxed.qualityLabel}...', 0.05, total: total);
          await YtStreamDownloader.download(
            muxed,
            outputPath,
            yt: yt,
            onBytes: (r, t) => emit(
              'Mengunduh ${muxed.qualityLabel}...',
              0.05 + 0.90 * (t <= 0 ? 0 : r / t),
              downloaded: r,
              total: t,
            ),
          );
          return _finish(outputPath, safeTitle, stamp, total, onProgress, emit);
        }
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
      await _safeDelete(videoPath);
      await _safeDelete(audioPath);

      final total = videoOnly.size.totalBytes + audio.size.totalBytes;
      return _finish(outputPath, safeTitle, stamp, total, onProgress, emit);
    } finally {
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
        downloadedBytes: total,
        totalBytes: total <= 0 ? 1 : total,
        speedBytesPerSecond: 0,
        isDone: true,
      ),
    );
    return exportPath;
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
