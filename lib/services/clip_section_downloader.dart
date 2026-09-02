import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'dash_clip_downloader.dart';
import 'ytdlp_exec_channel.dart';
import 'yt_dlp_service.dart';
import 'yt_stream_downloader.dart';

enum ClipSectionMode { dash, progressive, hls, ytdlp }

typedef ClipBatchPhaseCallback = void Function(String phase);

/// Potongan clip — batch manifest + mode lock + yt-dlp sekali untuk banyak section.
class ClipSectionDownloader {
  ClipSectionDownloader._();
  static final ClipSectionDownloader instance = ClipSectionDownloader._();

  _BatchState? _batch;

  /// Fetch yt-dlp format info sekali untuk stream HLS/DASH tersegmentasi.
  Future<ClipSectionMode> beginBatch({
    required String videoId,
    required int height,
    Duration? videoDuration,
    ClipBatchPhaseCallback? onPhase,
  }) async {
    _batch = _BatchState(
      videoId: videoId,
      height: height,
      videoDuration: videoDuration,
    );
    onPhase?.call('Menyiapkan stream potongan...');

    await YtDlpService.instance.ensureReady();
    final ytdlpInfo = await _fetchSegmentedInfo(videoId, height);
    _batch!.ytdlpInfo = ytdlpInfo;
    _batch!.lockedMode = ClipSectionMode.dash;
    onPhase?.call('Segment paralel · cuma potongan hook');
    return ClipSectionMode.dash;
  }

  Future<Map<String, dynamic>> _fetchSegmentedInfo(
    String videoId,
    int height,
  ) async {
    final tries = <String?>[
      YtDlpService.formatForSection(height),
      YtDlpService.formatForHeight(height),
      null, // semua format — scan DASH di Dart
    ];
    Object? last;
    for (final fmt in tries) {
      try {
        final info = await YtdlpExecChannel.instance.dumpVideoJsonMap(
          videoId: videoId,
          format: fmt,
        );
        if (DashClipDownloader.instance.hasSegmentedStreams(
          info,
          maxHeight: height,
        )) {
          return info;
        }
      } catch (e) {
        last = e;
      }
    }
    throw Exception(
      last != null
          ? 'Stream potongan tidak tersedia ($last).'
          : 'Stream potongan HLS/DASH tidak tersedia untuk video ini.',
    );
  }

  void endBatch() => _batch = null;

  ClipSectionMode get batchMode => _batch?.lockedMode ?? ClipSectionMode.ytdlp;

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
    final mode = _batch?.lockedMode ?? ClipSectionMode.dash;

    if (mode == ClipSectionMode.dash && _batch?.ytdlpInfo != null) {
      return _downloadViaDash(
        sectionStart: sectionStart,
        sectionEnd: sectionEnd,
        outputDir: outputDir,
        onProgress: onProgress,
        estimatedTotalBytes: estimatedTotalBytes,
        videoDuration: videoDuration ?? _batch?.videoDuration,
        info: _batch!.ytdlpInfo!,
        maxHeight: height,
      );
    }

    throw StateError('Mode unduh potongan tidak didukung');
  }

  ClipSectionMode _detectMode(_BatchState batch, int height) {
    final info = batch.ytdlpInfo;
    if (info != null) {
      final streams = DashClipDownloader.instance.pickStreams(info);
      final vFrags = streams.video == null
          ? <dynamic>[]
          : DashClipDownloader.instance.fragmentsFromFormat(streams.video!);
      if (vFrags.isNotEmpty) return ClipSectionMode.dash;
    }
    final android = batch.androidManifest;
    if (android != null && _hasAndroidProgressive(android, height)) {
      return ClipSectionMode.progressive;
    }
    final ios = batch.iosManifest;
    if (ios != null && _hasHls(ios, height)) {
      return ClipSectionMode.hls;
    }
    return ClipSectionMode.ytdlp;
  }

  bool _hasAndroidProgressive(StreamManifest manifest, int height) {
    if (height <= 360) {
      for (final m in manifest.muxed) {
        if (m.videoResolution.height <= height && _isAndroidStream(m)) {
          return true;
        }
      }
    }
    for (final v in manifest.videoOnly) {
      if (v.videoResolution.height <= height && _isAndroidStream(v)) {
        return true;
      }
    }
    return false;
  }

  bool _hasHls(StreamManifest manifest, int height) {
    for (final s in manifest.hls) {
      if (s is HlsMuxedStreamInfo && s.videoResolution.height <= height) {
        return true;
      }
      if (s is HlsVideoStreamInfo && s.videoResolution.height <= height) {
        return true;
      }
    }
    return false;
  }

  Future<String> _downloadViaDash({
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required YtProgressCallback onProgress,
    required int estimatedTotalBytes,
    Duration? videoDuration,
    required Map<String, dynamic> info,
    int maxHeight = 1080,
  }) async {
    final streams = DashClipDownloader.instance.pickStreams(
      info,
      maxHeight: maxHeight,
    );
    if (streams.video == null) {
      throw StateError('Stream video DASH tidak ada');
    }
    final durSec =
        videoDuration?.inSeconds.toDouble() ??
        (info['duration'] as num?)?.toDouble() ??
        (sectionEnd + 60);
    return DashClipDownloader.instance.downloadSection(
      videoFmt: streams.video!,
      audioFmt: streams.audio,
      sectionStart: sectionStart,
      sectionEnd: sectionEnd,
      outputDir: outputDir,
      videoDurationSec: durSec,
      onProgress: onProgress,
      estimatedTotalBytes: estimatedTotalBytes,
    );
  }

  Future<String> _downloadViaProgressiveRange({
    required String videoId,
    required int height,
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required YtProgressCallback onProgress,
    required int estimatedTotalBytes,
    Duration? videoDuration,
    StreamManifest? manifest,
  }) async {
    await Directory(outputDir).create(recursive: true);
    onProgress(
      YtDownloadProgress(
        progress01: 0.05,
        phase: 'Mengunduh potongan (Range)...',
        totalBytes: estimatedTotalBytes,
      ),
    );

    StreamManifest? m = manifest;
    if (m == null) {
      final yt = YoutubeExplode();
      try {
        m = await yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [YoutubeApiClient.androidSdkless],
        );
      } finally {
        yt.close();
      }
    }

    final durSec =
        videoDuration?.inSeconds.toDouble() ??
        _guessDurationSec(m) ??
        (sectionEnd + 120);
    if (durSec <= 0) throw StateError('Durasi video tidak diketahui');

    if (height <= 360) {
      final muxed = _pickMuxed(m, height, androidOnly: true);
      if (muxed != null && muxed.size.totalBytes > 0) {
        return _finishMuxed(
          stream: muxed,
          outputDir: outputDir,
          sectionStart: sectionStart,
          sectionEnd: sectionEnd,
          durSec: durSec,
          estimatedTotalBytes: estimatedTotalBytes,
          onProgress: onProgress,
          label: 'Range',
        );
      }
    }

    final video = _pickVideo(m, height, androidOnly: true);
    final audio = _pickAudio(m, androidOnly: true);
    if (video == null || audio == null) {
      throw StateError('Progressive ANDROID tidak tersedia');
    }

    final vPath = p.join(outputDir, 'range_v.raw');
    final aPath = p.join(outputDir, 'range_a.raw');
    final vEst = _estimateSectionBytes(
      video.size.totalBytes,
      durSec,
      sectionStart,
      sectionEnd,
      estimatedTotalBytes ~/ 2,
    );
    final aEst = _estimateSectionBytes(
      audio.size.totalBytes,
      durSec,
      sectionStart,
      sectionEnd,
      estimatedTotalBytes ~/ 2,
    );

    StreamTimeRangeResult? vRange;
    var vGot = 0;
    var aGot = 0;
    var vSpeed = 0.0;
    var aSpeed = 0.0;

    await Future.wait([
      () async {
        vRange = await YtStreamDownloader.downloadStreamTimeRange(
          video,
          vPath,
          rangeStartSec: sectionStart,
          rangeEndSec: sectionEnd,
          videoDurationSec: durSec,
          onBytes: (got, total, speed) {
            vGot = got;
            vSpeed = speed;
            _emitCombined(
              onProgress,
              vGot + aGot,
              vEst + aEst,
              vSpeed + aSpeed,
              'Mengunduh potongan (Range)...',
            );
          },
        );
      }(),
      () async {
        await YtStreamDownloader.downloadStreamTimeRange(
          audio,
          aPath,
          rangeStartSec: sectionStart,
          rangeEndSec: sectionEnd,
          videoDurationSec: durSec,
          onBytes: (got, total, speed) {
            aGot = got;
            aSpeed = speed;
            _emitCombined(
              onProgress,
              vGot + aGot,
              vEst + aEst,
              vSpeed + aSpeed,
              'Mengunduh potongan (Range)...',
            );
          },
        );
      }(),
    ]);

    onProgress(
      YtDownloadProgress(
        progress01: 0.78,
        phase: 'Menggabungkan audio+video...',
        downloadedBytes: vGot + aGot,
        totalBytes: vEst + aEst,
        speedBytesPerSecond: vSpeed + aSpeed,
      ),
    );

    final trimStart = (sectionStart - vRange!.fileStartSec).clamp(
      0.0,
      sectionEnd,
    );
    return YtDlpService.instance.remuxLocalClip(
      videoPath: vPath,
      audioPath: aPath,
      outputDir: outputDir,
      trimStartSec: trimStart,
      durationSec: sectionEnd - sectionStart,
      onProgress: onProgress,
    );
  }

  Future<String> _finishMuxed({
    required StreamInfo stream,
    required String outputDir,
    required double sectionStart,
    required double sectionEnd,
    required double durSec,
    required int estimatedTotalBytes,
    required YtProgressCallback onProgress,
    required String label,
  }) async {
    final rawPath = p.join(outputDir, 'range_mux.raw');
    final est = _estimateSectionBytes(
      stream.size.totalBytes,
      durSec,
      sectionStart,
      sectionEnd,
      estimatedTotalBytes,
    );
    var lastGot = 0;
    var lastSpeed = 0.0;
    final range = await YtStreamDownloader.downloadStreamTimeRange(
      stream,
      rawPath,
      rangeStartSec: sectionStart,
      rangeEndSec: sectionEnd,
      videoDurationSec: durSec,
      onBytes: (got, total, speed) {
        lastGot = got;
        lastSpeed = speed;
        onProgress(
          YtDownloadProgress(
            progress01: (0.05 + 0.75 * (got / (total > 0 ? total : est))).clamp(
              0.05,
              0.80,
            ),
            phase: 'Mengunduh potongan ($label)...',
            downloadedBytes: got,
            totalBytes: total > 0 ? total : est,
            speedBytesPerSecond: speed,
          ),
        );
      },
    );
    onProgress(
      YtDownloadProgress(
        progress01: 0.82,
        phase: 'Merapikan potongan...',
        downloadedBytes: lastGot,
        totalBytes: est,
        speedBytesPerSecond: lastSpeed,
      ),
    );
    final trimStart = (sectionStart - range.fileStartSec).clamp(
      0.0,
      sectionEnd,
    );
    return YtDlpService.instance.remuxLocalClip(
      videoPath: rawPath,
      outputDir: outputDir,
      trimStartSec: trimStart,
      durationSec: sectionEnd - sectionStart,
      onProgress: onProgress,
    );
  }

  Future<String> _downloadViaHls({
    required String videoId,
    required int height,
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required YtProgressCallback onProgress,
    required int estimatedTotalBytes,
    Duration? videoDuration,
    StreamManifest? manifest,
  }) async {
    await Directory(outputDir).create(recursive: true);
    onProgress(
      YtDownloadProgress(
        progress01: 0.05,
        phase: 'Mengunduh potongan (HLS)...',
        totalBytes: estimatedTotalBytes,
      ),
    );

    StreamManifest? m = manifest;
    if (m == null) {
      final yt = YoutubeExplode();
      try {
        m = await yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [YoutubeApiClient.ios],
        );
      } finally {
        yt.close();
      }
    }

    final durSec =
        videoDuration?.inSeconds.toDouble() ??
        _guessDurationSec(m) ??
        (sectionEnd + 60);

    final muxed = m.hls.whereType<HlsMuxedStreamInfo>().toList()
      ..sort(
        (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height),
      );
    HlsMuxedStreamInfo? pickMuxed;
    for (final s in muxed) {
      if (s.videoResolution.height <= height) {
        pickMuxed = s;
        break;
      }
    }
    pickMuxed ??= muxed.isEmpty ? null : muxed.last;

    if (pickMuxed != null) {
      return _finishHlsMuxed(
        pickMuxed,
        outputDir: outputDir,
        sectionStart: sectionStart,
        sectionEnd: sectionEnd,
        durSec: durSec,
        estimatedTotalBytes: estimatedTotalBytes,
        onProgress: onProgress,
      );
    }

    final videos = m.hls.whereType<HlsVideoStreamInfo>().toList()
      ..sort(
        (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height),
      );
    HlsVideoStreamInfo? pickVideo;
    for (final s in videos) {
      if (s.videoResolution.height <= height) {
        pickVideo = s;
        break;
      }
    }
    pickVideo ??= videos.isEmpty ? null : videos.last;

    final audios = m.hls.whereType<HlsAudioStreamInfo>().toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final pickAudio = audios.isEmpty ? null : audios.first;

    if (pickVideo == null || pickAudio == null) {
      throw StateError('HLS video/audio tidak tersedia');
    }

    final videoStream = pickVideo;
    final audioStream = pickAudio;
    final vPath = p.join(outputDir, 'hls_v.raw');
    final aPath = p.join(outputDir, 'hls_a.raw');
    final vEst = _estimateSectionBytes(
      videoStream.size.totalBytes,
      durSec,
      sectionStart,
      sectionEnd,
      estimatedTotalBytes ~/ 2,
    );
    final aEst = _estimateSectionBytes(
      audioStream.size.totalBytes,
      durSec,
      sectionStart,
      sectionEnd,
      estimatedTotalBytes ~/ 2,
    );

    HlsTimeRangeResult? vRange;
    var vGot = 0;
    var aGot = 0;
    var vSpeed = 0.0;
    var aSpeed = 0.0;

    await Future.wait([
      () async {
        vRange = await YtStreamDownloader.downloadHlsTimeRange(
          videoStream,
          vPath,
          rangeStartSec: sectionStart,
          rangeEndSec: sectionEnd,
          onBytes: (got, total, speed) {
            vGot = got;
            vSpeed = speed;
            _emitCombined(
              onProgress,
              vGot + aGot,
              vEst + aEst,
              vSpeed + aSpeed,
              'Mengunduh potongan (HLS)...',
            );
          },
        );
      }(),
      () async {
        await YtStreamDownloader.downloadHlsTimeRange(
          audioStream,
          aPath,
          rangeStartSec: sectionStart,
          rangeEndSec: sectionEnd,
          onBytes: (got, total, speed) {
            aGot = got;
            aSpeed = speed;
            _emitCombined(
              onProgress,
              vGot + aGot,
              vEst + aEst,
              vSpeed + aSpeed,
              'Mengunduh potongan (HLS)...',
            );
          },
        );
      }(),
    ]);

    onProgress(
      YtDownloadProgress(
        progress01: 0.78,
        phase: 'Menggabungkan audio+video...',
        downloadedBytes: vGot + aGot,
        totalBytes: vEst + aEst,
        speedBytesPerSecond: vSpeed + aSpeed,
      ),
    );

    final trimStart = (sectionStart - vRange!.firstSegmentStartSec).clamp(
      0.0,
      sectionEnd,
    );
    return YtDlpService.instance.remuxLocalClip(
      videoPath: vPath,
      audioPath: aPath,
      outputDir: outputDir,
      trimStartSec: trimStart,
      durationSec: sectionEnd - sectionStart,
      onProgress: onProgress,
    );
  }

  Future<String> _finishHlsMuxed(
    HlsMuxedStreamInfo pickMuxed, {
    required String outputDir,
    required double sectionStart,
    required double sectionEnd,
    required double durSec,
    required int estimatedTotalBytes,
    required YtProgressCallback onProgress,
  }) async {
    final rawPath = p.join(outputDir, 'hls_mux.raw');
    final est = _estimateSectionBytes(
      pickMuxed.size.totalBytes,
      durSec,
      sectionStart,
      sectionEnd,
      estimatedTotalBytes,
    );
    var lastGot = 0;
    var lastSpeed = 0.0;
    final range = await YtStreamDownloader.downloadHlsTimeRange(
      pickMuxed,
      rawPath,
      rangeStartSec: sectionStart,
      rangeEndSec: sectionEnd,
      onBytes: (got, total, speed) {
        lastGot = got;
        lastSpeed = speed;
        onProgress(
          YtDownloadProgress(
            progress01: (0.05 + 0.75 * (got / (total > 0 ? total : est))).clamp(
              0.05,
              0.80,
            ),
            phase: 'Mengunduh potongan (HLS)...',
            downloadedBytes: got,
            totalBytes: total > 0 ? total : est,
            speedBytesPerSecond: speed,
          ),
        );
      },
    );
    onProgress(
      YtDownloadProgress(
        progress01: 0.82,
        phase: 'Merapikan potongan...',
        downloadedBytes: lastGot,
        totalBytes: est,
        speedBytesPerSecond: lastSpeed,
      ),
    );
    final trimStart = (sectionStart - range.firstSegmentStartSec).clamp(
      0.0,
      sectionEnd,
    );
    return YtDlpService.instance.remuxLocalClip(
      videoPath: rawPath,
      outputDir: outputDir,
      trimStartSec: trimStart,
      durationSec: sectionEnd - sectionStart,
      onProgress: onProgress,
    );
  }

  void _emitCombined(
    YtProgressCallback onProgress,
    int got,
    int total,
    double speed,
    String phase,
  ) {
    onProgress(
      YtDownloadProgress(
        progress01: (0.05 + 0.75 * (got / (total > 0 ? total : 1))).clamp(
          0.05,
          0.80,
        ),
        phase: phase,
        downloadedBytes: got,
        totalBytes: total > 0 ? total : got,
        speedBytesPerSecond: speed,
      ),
    );
  }

  MuxedStreamInfo? _pickMuxed(
    StreamManifest manifest,
    int height, {
    bool androidOnly = false,
  }) {
    final candidates =
        manifest.muxed
            .where((s) => s.videoResolution.height <= height)
            .where((s) => !androidOnly || _isAndroidStream(s))
            .toList()
          ..sort(
            (a, b) =>
                b.videoResolution.height.compareTo(a.videoResolution.height),
          );
    return candidates.isEmpty ? null : candidates.first;
  }

  VideoOnlyStreamInfo? _pickVideo(
    StreamManifest manifest,
    int height, {
    bool androidOnly = false,
  }) {
    final candidates =
        manifest.videoOnly
            .where((s) => s.videoResolution.height <= height)
            .where((s) => !androidOnly || _isAndroidStream(s))
            .toList()
          ..sort((a, b) {
            final aScore = _isAndroidStream(a) ? 2 : 0;
            final bScore = _isAndroidStream(b) ? 2 : 0;
            if (aScore != bScore) return bScore - aScore;
            return b.videoResolution.height.compareTo(a.videoResolution.height);
          });
    return candidates.isEmpty ? null : candidates.first;
  }

  AudioOnlyStreamInfo? _pickAudio(
    StreamManifest manifest, {
    bool androidOnly = false,
  }) {
    final candidates =
        manifest.audioOnly
            .where((s) => !androidOnly || _isAndroidStream(s))
            .toList()
          ..sort((a, b) {
            final aScore = _isAndroidStream(a) ? 2 : 0;
            final bScore = _isAndroidStream(b) ? 2 : 0;
            if (aScore != bScore) return bScore - aScore;
            return b.bitrate.compareTo(a.bitrate);
          });
    return candidates.isEmpty ? null : candidates.first;
  }

  bool _isAndroidStream(StreamInfo s) =>
      (s.url.queryParameters['c'] ?? '').toUpperCase() == 'ANDROID';

  int _estimateSectionBytes(
    int fullBytes,
    double durSec,
    double start,
    double end,
    int fallback,
  ) {
    if (fullBytes > 0 && durSec > 0) {
      return ((fullBytes * (end - start) / durSec) * 1.2).round().clamp(
        256 * 1024,
        fullBytes,
      );
    }
    return fallback > 0 ? fallback : 5 * 1024 * 1024;
  }

  double? _guessDurationSec(StreamManifest manifest) {
    for (final s in [...manifest.videoOnly, ...manifest.muxed]) {
      final total = s.size.totalBytes;
      final br = s.bitrate.bitsPerSecond;
      if (total > 0 && br > 0) return total / (br / 8);
    }
    return null;
  }
}

class _BatchState {
  _BatchState({
    required this.videoId,
    required this.height,
    this.videoDuration,
  });

  final String videoId;
  final int height;
  final Duration? videoDuration;
  StreamManifest? androidManifest;
  StreamManifest? iosManifest;
  Map<String, dynamic>? ytdlpInfo;
  ClipSectionMode? lockedMode;
}

class ClipSection {
  const ClipSection({required this.startSec, required this.endSec});
  final double startSec;
  final double endSec;
}
