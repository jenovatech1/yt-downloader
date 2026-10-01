import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'yt_dlp_service.dart';

enum ClipSectionMode { ytdlpFull, ytdlp }

typedef ClipBatchPhaseCallback = void Function(String phase);

/// Get Clip potongan: pakai jalur yang sama dengan Download penuh (yt-dlp),
/// karena Range/DASH/HLS sering 403 sementara unduh full 1080p stabil.
class ClipSectionDownloader {
  ClipSectionDownloader._();
  static final ClipSectionDownloader instance = ClipSectionDownloader._();

  _BatchState? _batch;

  Future<ClipSectionMode> beginBatch({
    required String videoId,
    required int height,
    Duration? videoDuration,
    int estimatedFullBytes = 0,
    ClipBatchPhaseCallback? onPhase,
  }) async {
    _batch = _BatchState(
      videoId: videoId,
      height: height,
      videoDuration: videoDuration,
      estimatedFullBytes: estimatedFullBytes,
    );
    onPhase?.call('Siap unduh potongan (jalur sama Download)...');
    await YtDlpService.instance.ensureReady();
    _batch!.lockedMode = ClipSectionMode.ytdlpFull;
    return ClipSectionMode.ytdlpFull;
  }

  void endBatch() => _batch = null;

  ClipSectionMode get batchMode =>
      _batch?.lockedMode ?? ClipSectionMode.ytdlpFull;

  Future<String> download({
    required String videoId,
    required int height,
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required YtProgressCallback onProgress,
    int estimatedTotalBytes = 0,
    Duration? videoDuration,
  }) async {
    await Directory(outputDir).create(recursive: true);
    final batch = _batch;

    // Sudah punya file full dari klip sebelumnya → potong lokal.
    final existing = batch?.fullVideoPath;
    if (existing != null && await File(existing).exists()) {
      return _cutFromFull(
        fullPath: existing,
        sectionStart: sectionStart,
        sectionEnd: sectionEnd,
        outputDir: outputDir,
        onProgress: onProgress,
        estimatedTotalBytes: estimatedTotalBytes,
      );
    }

    // Unduh penuh dulu (jalur yang sama dengan tombol Download — terbukti 1080p),
    // lalu potong tiap hook lokal. Hindari Range/DASH section yang sering 403.
    onProgress(
      YtDownloadProgress(
        progress01: 0.05,
        phase: 'Mengunduh video ${height}p penuh (sama seperti Download)...',
        totalBytes: batch?.estimatedFullBytes ?? estimatedTotalBytes,
      ),
    );
    final fullPath = await _ensureFullVideo(
      videoId: videoId,
      height: height,
      onProgress: onProgress,
    );
    return _cutFromFull(
      fullPath: fullPath,
      sectionStart: sectionStart,
      sectionEnd: sectionEnd,
      outputDir: outputDir,
      onProgress: onProgress,
      estimatedTotalBytes: estimatedTotalBytes,
    );
  }

  Future<String> _ensureFullVideo({
    required String videoId,
    required int height,
    required YtProgressCallback onProgress,
  }) async {
    final batch = _batch;
    final cached = batch?.fullVideoPath;
    if (cached != null && await File(cached).exists()) {
      return cached;
    }

    final baseDir = batch == null
        ? Directory.systemTemp.path
        : p.dirname(p.dirname(batch.fullDirHint ?? Directory.systemTemp.path));
    final fullDir = Directory(
      p.join(
        batch?.workRoot ?? baseDir,
        'full_${videoId}_${height}p',
      ),
    );
    await fullDir.create(recursive: true);

    final path = await YtDlpService.instance.downloadVideo(
      videoId: videoId,
      height: height,
      outputDir: fullDir.path,
      estimatedTotalBytes: batch?.estimatedFullBytes ?? 0,
      onProgress: (p) {
        onProgress(
          YtDownloadProgress(
            progress01: (0.1 + 0.75 * p.progress01).clamp(0.1, 0.9),
            phase: p.phase.contains('Selesai')
                ? 'Video penuh siap · merapikan potongan...'
                : 'Unduh penuh ${height}p · ${p.phase}',
            downloadedBytes: p.downloadedBytes,
            totalBytes: p.totalBytes > 0
                ? p.totalBytes
                : (batch?.estimatedFullBytes ?? p.downloadedBytes),
            speedBytesPerSecond: p.speedBytesPerSecond,
          ),
        );
      },
    );
    if (batch != null) {
      batch.fullVideoPath = path;
    }
    return path;
  }

  Future<String> _cutFromFull({
    required String fullPath,
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required YtProgressCallback onProgress,
    required int estimatedTotalBytes,
  }) async {
    final dur = (sectionEnd - sectionStart).clamp(0.5, 600.0);
    onProgress(
      YtDownloadProgress(
        progress01: 0.92,
        phase: 'Memotong dari video penuh...',
        downloadedBytes: estimatedTotalBytes,
        totalBytes: estimatedTotalBytes > 0 ? estimatedTotalBytes : 1,
      ),
    );
    return YtDlpService.instance.remuxLocalClip(
      videoPath: fullPath,
      outputDir: outputDir,
      trimStartSec: sectionStart,
      durationSec: dur,
      onProgress: onProgress,
    );
  }

  /// Dipanggil pipeline agar folder full sejajar workDir klip.
  void setWorkRoot(String workDirPath) {
    _batch?.workRoot = workDirPath;
    _batch?.fullDirHint = workDirPath;
  }
}

class _BatchState {
  _BatchState({
    required this.videoId,
    required this.height,
    this.videoDuration,
    this.estimatedFullBytes = 0,
  });

  final String videoId;
  final int height;
  final Duration? videoDuration;
  final int estimatedFullBytes;
  String? workRoot;
  String? fullDirHint;
  String? fullVideoPath;
  ClipSectionMode? lockedMode;
}

class ClipSection {
  const ClipSection({required this.startSec, required this.endSec});
  final double startSec;
  final double endSec;
}
