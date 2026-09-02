import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:extractor/extractor.dart';
import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'clip_section_downloader.dart';
import 'ytdlp_exec_channel.dart';

/// Snapshot progress unduhan yt-dlp (%, byte, kecepatan).
class YtDownloadProgress {
  const YtDownloadProgress({
    required this.progress01,
    required this.phase,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSecond = 0,
  });

  final double progress01;
  final String phase;
  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSecond;
}

typedef YtProgressCallback = void Function(YtDownloadProgress progress);

/// yt-dlp via youtubedl-android (engine sama Seal).
class YtDlpService {
  YtDlpService._();
  static final YtDlpService instance = YtDlpService._();

  final _dl = YoutubeDLFlutter.instance;
  bool _ready = false;
  Future<void>? _initFuture;

  Future<void> ensureReady() {
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    if (_ready) return;
    final init = await _dl.initialize(enableFFmpeg: true, enableAria2c: true);
    if (!init.success) {
      _initFuture = null;
      throw Exception(init.errorMessage ?? 'Gagal init yt-dlp');
    }
    _ready = true;
    unawaited(_tryUpdate());
  }

  Future<void> _tryUpdate() async {
    try {
      await _dl.updateYoutubeDL(channel: UpdateChannel.stable);
    } catch (_) {}
  }

  static String formatForHeight(int height) {
    final h = height.clamp(144, 1080);
    const a =
        '(bestaudio[format_note*=original][ext=m4a]/'
        'bestaudio[format_note*=original]/'
        'bestaudio[ext=m4a]/bestaudio)';
    // Prefer H.264 (avc1) biar Klippod/FFprobe bisa baca width/height.
    // JANGAN fallback ke bare `best` — yt-dlp treat warning itu sebagai gagal.
    return 'bestvideo[height<=$h][vcodec^=avc1][ext=mp4]+$a/'
        'bestvideo[height<=$h][vcodec*=avc1]+$a/'
        'bestvideo[height<=$h][vcodec^=avc]+$a/'
        'bestvideo[height<=$h][ext=mp4]+$a/'
        'bestvideo[height<=$h]+$a/'
        'bestvideo[height<=360]+$a/'
        'bv*+ba/b';
  }

  /// Section: DASH only (tanpa muxed `b`) biar YouTube tidak throttle ~0.2 Mbps.
  static String formatForSection(int height) {
    final h = height.clamp(144, 1080);
    const a =
        '(bestaudio[format_note*=original][ext=m4a]/'
        'bestaudio[format_note*=original]/'
        'bestaudio[ext=m4a]/bestaudio)';
    return 'bestvideo[height<=$h][vcodec^=avc1][ext=mp4]+$a/'
        'bestvideo[height<=$h][vcodec*=avc1]+$a/'
        'bestvideo[height<=$h][ext=mp4]+$a/'
        'bestvideo[height<=$h]+$a/'
        'bv*+ba';
  }

  Map<String?, String?> get _baseArgs => {
    '--extractor-args': 'youtube:player_client=default,-android_sdkless',
    '--merge-output-format': 'mp4',
    '--retries': '15',
    '--fragment-retries': '15',
    '--concurrent-fragments': '16',
  };

  /// Estimasi byte satu potongan dari ukuran video full (bukan tebak 500KB/s).
  static int estimateSectionBytes({
    required double startSec,
    required double endSec,
    int fullVideoBytes = 0,
    double videoDurationSec = 0,
  }) {
    final sec = (endSec - startSec).clamp(30.0, 120.0);
    if (fullVideoBytes > 0 && videoDurationSec > 0) {
      return (fullVideoBytes * sec / videoDurationSec * 1.05).round().clamp(
        256 * 1024,
        fullVideoBytes,
      );
    }
    return (sec * 280 * 1024).round();
  }

  Map<String?, String?> _sectionEngineArgs({
    required double sectionStart,
    required double sectionEnd,
  }) {
    final custom = Map<String?, String?>.from(_baseArgs);
    custom['--download-sections'] =
        '*${sectionStart.toStringAsFixed(3)}-${sectionEnd.toStringAsFixed(3)}';
    custom['--remux-video'] = 'mp4';
    custom['--postprocessor-args'] = 'ffmpeg:-movflags +faststart';
    return custom;
  }

  /// Config hanya berisi daftar --download-sections (engine lewat customOptions).
  Future<File> _writeSectionsOnlyConfig({
    required String outputDir,
    required List<ClipSection> sections,
  }) async {
    final sb = StringBuffer();
    for (final s in sections) {
      sb.writeln(
        '--download-sections "*${s.startSec.toStringAsFixed(3)}-${s.endSec.toStringAsFixed(3)}"',
      );
    }
    final f = File(p.join(outputDir, 'clip_sections.conf'));
    await f.writeAsString(sb.toString());
    return f;
  }

  /// Potongan via yt-dlp --download-sections (FFmpeg linear, LAMBAT).
  /// Get Clip pakai [ClipSectionDownloader] + DASH fragment, bukan ini.
  Future<String> downloadVideoSection({
    required String videoId,
    required int height,
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required YtProgressCallback onProgress,
    int estimatedTotalBytes = 0,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId =
        'vsec_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final custom = _sectionEngineArgs(
      sectionStart: sectionStart,
      sectionEnd: sectionEnd,
    );

    final tracker = _ProgressTracker(
      processId: processId,
      phaseLabel: 'Mengunduh potongan (yt-dlp)...',
      estimatedTotalBytes: estimatedTotalBytes,
      onProgress: onProgress,
      lockSlimEstimate: estimatedTotalBytes > 0,
      watchDir: outputDir,
    );
    final subs = tracker.bind(_dl);

    try {
      onProgress(
        YtDownloadProgress(
          progress01: 0.02,
          phase: 'Mengunduh potongan (yt-dlp)...',
          totalBytes: estimatedTotalBytes,
        ),
      );
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_clip.%(ext)s',
          format: formatForHeight(height),
          noPlaylist: true,
          processId: processId,
          customOptions: custom,
        ),
      );
      if (result.status != OperationStatus.success) {
        final recovered = await _tryRecoverOutput(
          outputDir: outputDir,
          preferred: result.outputPath,
          videoId: videoId,
        );
        if (recovered != null) {
          final size = await File(recovered).length();
          onProgress(
            YtDownloadProgress(
              progress01: 1,
              phase: 'Selesai unduh',
              downloadedBytes: size,
              totalBytes: size,
            ),
          );
          return recovered;
        }
        throw Exception(result.errorMessage ?? 'yt-dlp gagal unduh potongan');
      }
      final out = await _findOutput(
        outputDir,
        preferred: result.outputPath,
        videoId: videoId,
      );
      final size = await File(out).length();
      onProgress(
        YtDownloadProgress(
          progress01: 1,
          phase: 'Selesai unduh',
          downloadedBytes: size,
          totalBytes: size,
        ),
      );
      return out;
    } finally {
      await subs.cancel();
    }
  }

  Future<String> downloadVideo({
    required String videoId,
    required int height,
    required String outputDir,
    required YtProgressCallback onProgress,
    int estimatedTotalBytes = 0,
    double? sectionStart,
    double? sectionEnd,
    Duration? videoDuration,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final isSection =
        sectionStart != null && sectionEnd != null && sectionEnd > sectionStart;

    if (isSection) {
      return downloadVideoSection(
        videoId: videoId,
        height: height,
        sectionStart: sectionStart,
        sectionEnd: sectionEnd,
        outputDir: outputDir,
        onProgress: onProgress,
        estimatedTotalBytes: estimatedTotalBytes,
      );
    }

    final processId = 'v_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final custom = Map<String?, String?>.from(_baseArgs);

    final tracker = _ProgressTracker(
      processId: processId,
      phaseLabel: 'Mengunduh (yt-dlp)...',
      estimatedTotalBytes: estimatedTotalBytes,
      onProgress: onProgress,
      watchDir: outputDir,
    );
    final subs = tracker.bind(_dl);

    try {
      onProgress(
        YtDownloadProgress(
          progress01: 0.02,
          phase: 'Menyiapkan yt-dlp...',
          totalBytes: estimatedTotalBytes,
        ),
      );
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_%(height)sp.%(ext)s',
          format: formatForHeight(height),
          noPlaylist: true,
          processId: processId,
          customOptions: custom,
        ),
      );
      if (result.status != OperationStatus.success) {
        final recovered = await _tryRecoverOutput(
          outputDir: outputDir,
          preferred: result.outputPath,
          videoId: videoId,
        );
        if (recovered != null) {
          final size = await File(recovered).length();
          onProgress(
            YtDownloadProgress(
              progress01: 1,
              phase: 'Selesai unduh',
              downloadedBytes: size,
              totalBytes: size,
            ),
          );
          return recovered;
        }
        final err = result.errorMessage ?? 'yt-dlp gagal unduh video';
        if (_isBenignYtDlpWarning(err)) {
          throw Exception(
            'Unduh gagal setelah peringatan yt-dlp. Coba lagi atau ganti kualitas.',
          );
        }
        throw Exception(err);
      }
      final out = await _findOutput(
        outputDir,
        preferred: result.outputPath,
        videoId: videoId,
      );
      final size = await File(out).length();
      onProgress(
        YtDownloadProgress(
          progress01: 1,
          phase: 'Selesai unduh',
          downloadedBytes: size,
          totalBytes: size,
        ),
      );
      return out;
    } finally {
      await subs.cancel();
    }
  }

  /// Alias — pakai [downloadVideoSection].
  Future<String> downloadVideoSectionFallback({
    required String videoId,
    required int height,
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required YtProgressCallback onProgress,
    int estimatedTotalBytes = 0,
  }) => downloadVideoSection(
    videoId: videoId,
    height: height,
    sectionStart: sectionStart,
    sectionEnd: sectionEnd,
    outputDir: outputDir,
    onProgress: onProgress,
    estimatedTotalBytes: estimatedTotalBytes,
  );

  /// Satu yt-dlp init untuk banyak potongan.
  Future<List<String>> downloadVideoSectionsBatch({
    required String videoId,
    required int height,
    required String outputDir,
    required List<ClipSection> sections,
    required YtProgressCallback onProgress,
    int estimatedTotalBytes = 0,
  }) async {
    if (sections.isEmpty) return [];
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final confFile = await _writeSectionsOnlyConfig(
      outputDir: outputDir,
      sections: sections,
    );

    final processId =
        'vbatch_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final custom = Map<String?, String?>.from(_baseArgs);
    custom['--config-location'] = confFile.path;
    custom['--remux-video'] = 'mp4';
    custom['--postprocessor-args'] = 'ffmpeg:-movflags +faststart';

    final tracker = _ProgressTracker(
      processId: processId,
      phaseLabel: 'Mengunduh potongan (yt-dlp)...',
      estimatedTotalBytes: estimatedTotalBytes,
      onProgress: onProgress,
      lockSlimEstimate: estimatedTotalBytes > 0,
      watchDir: outputDir,
    );
    final subs = tracker.bind(_dl);

    try {
      onProgress(
        YtDownloadProgress(
          progress01: 0.02,
          phase: 'yt-dlp: mengekstrak info video...',
          totalBytes: estimatedTotalBytes,
        ),
      );
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_clip_%(autonumber)03d.%(ext)s',
          format: formatForHeight(height),
          noPlaylist: true,
          processId: processId,
          customOptions: custom,
        ),
      );
      if (result.status != OperationStatus.success) {
        final recovered = await _collectClipOutputs(outputDir, videoId);
        if (recovered.length >= sections.length) return recovered;
        throw Exception(result.errorMessage ?? 'yt-dlp batch potongan gagal');
      }
      final outs = await _collectClipOutputs(outputDir, videoId);
      if (outs.length < sections.length) {
        throw Exception(
          'Hanya ${outs.length}/${sections.length} potongan dari yt-dlp',
        );
      }
      onProgress(
        YtDownloadProgress(
          progress01: 1,
          phase: 'Selesai unduh batch',
          downloadedBytes: estimatedTotalBytes,
          totalBytes: estimatedTotalBytes,
        ),
      );
      return outs.take(sections.length).toList();
    } finally {
      await subs.cancel();
    }
  }

  Future<List<String>> _collectClipOutputs(String dir, String videoId) async {
    final folder = Directory(dir);
    if (!await folder.exists()) return [];
    final files = <File>[];
    await for (final entity in folder.list(recursive: true)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if ({'.mp4', '.mkv', '.webm'}.contains(ext)) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final out = <String>[];
    for (final f in files) {
      if (await f.length() > 2048) out.add(f.path);
    }
    return out;
  }

  /// Potong klip dari file video lokal (ffmpeg copy — cepat, tanpa re-encode).
  Future<String> cutClipFromFile({
    required String sourcePath,
    required String outputDir,
    required double startSec,
    required double endSec,
    required YtProgressCallback onProgress,
  }) {
    final dur = (endSec - startSec).clamp(0.5, 600.0);
    return remuxLocalClip(
      videoPath: sourcePath,
      outputDir: outputDir,
      trimStartSec: startSec,
      durationSec: dur,
      onProgress: onProgress,
    );
  }

  /// Trim + mux file lokal hasil unduh HLS segment.
  Future<String> remuxLocalClip({
    required String videoPath,
    required String outputDir,
    required double trimStartSec,
    required double durationSec,
    required YtProgressCallback onProgress,
    String? audioPath,
    double? audioTrimStartSec,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final vSize = await File(videoPath).length();
    final aSize = audioPath != null ? await File(audioPath).length() : 0;
    final estBytes = vSize + aSize;
    onProgress(
      YtDownloadProgress(
        progress01: 0.85,
        phase: audioPath == null
            ? 'Merapikan potongan...'
            : 'Menggabungkan audio+video...',
        downloadedBytes: (estBytes * 0.85).round(),
        totalBytes: estBytes,
      ),
    );

    final outputPath = p.join(outputDir, 'clip.mp4');
    final result = await YtdlpExecChannel.instance.muxLocalClip(
      videoPath: videoPath,
      audioPath: audioPath,
      outputPath: outputPath,
      videoTrimStartSec: trimStartSec,
      audioTrimStartSec: audioTrimStartSec,
      durationSec: durationSec,
    );
    final size = await File(result).length();
    onProgress(
      YtDownloadProgress(
        progress01: 1,
        phase: 'Klip siap',
        downloadedBytes: size,
        totalBytes: size,
      ),
    );
    return result;
  }

  /// Audio untuk Whisper: mono 16kHz 32kbps (sama desktop Klippod).
  /// Cap ~85 menit biar tetap di bawah limit upload Groq ~23 MB.
  static const groqMaxUploadBytes = 23 * 1024 * 1024;
  static const transcribeMaxSeconds = 85 * 60;
  static const slimAudioBytesPerSec = 4000; // 32 kbps

  /// DASH audio-only — engine sama unduh video, tanpa FFmpeg manual.
  static const _transcribeAudioFormat =
      'bestaudio[format_note*=original][ext=m4a]/'
      'bestaudio[format_note*=original]/'
      'bestaudio[ext=m4a]/bestaudio/ba/worst';

  /// Fallback kalau m4a masih >23 MB: yt-dlp extract MP3 (FFmpeg internal).
  static const _transcribeSlimFormat =
      'ba[format_note*=original][abr<=48]/'
      'ba[format_note*=original][abr<=64]/'
      'ba[format_note*=original]/'
      'ba[abr<=48]/ba[abr<=64]/worstaudio/ba/worst';

  Future<String> downloadAudio({
    required String videoId,
    required String outputDir,
    required YtProgressCallback onProgress,
    Duration? videoDuration,
    bool forTranscribe = true,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final durSec = videoDuration?.inSeconds ?? 0;
    final capSec = forTranscribe
        ? (durSec > 0
              ? math.min(durSec, transcribeMaxSeconds)
              : transcribeMaxSeconds)
        : (durSec > 0 ? durSec : 0);

    if (!forTranscribe) {
      return _downloadAudioDash(
        videoId: videoId,
        outputDir: outputDir,
        onProgress: onProgress,
        format:
            'bestaudio[format_note*=original][ext=m4a]/'
            'bestaudio[format_note*=original]/'
            'bestaudio[ext=m4a]/bestaudio/best',
        extractAudio: false,
      );
    }

    // Selalu slim 32kbps mono — video 25–60 menit full m4a bikin Groq Whisper lambat.
    final estimated = capSec > 0
        ? capSec * slimAudioBytesPerSec
        : 8 * 1024 * 1024;
    return _downloadAudioDash(
      videoId: videoId,
      outputDir: outputDir,
      onProgress: onProgress,
      format: _transcribeSlimFormat,
      extractAudio: true,
      capSec: capSec,
      estimated: estimated,
      phase: 'Mengunduh audio untuk Whisper...',
    );
  }

  Future<int> _estimateAudioBytes(
    String videoId, {
    int capSec = 0,
    int durSec = 0,
  }) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(
        videoId,
        ytClients: [YoutubeApiClient.androidSdkless, YoutubeApiClient.ios],
      );
      var bytes = 0;
      for (final a in manifest.audioOnly) {
        if (bytes <= 0 || a.size.totalBytes < bytes) {
          bytes = a.size.totalBytes;
        }
      }
      if (bytes > 0 && durSec > 0 && capSec > 0 && capSec < durSec) {
        bytes = (bytes * capSec / durSec).round();
      }
      if (bytes > 0) return bytes;
    } catch (_) {
    } finally {
      yt.close();
    }
    if (capSec > 0) return capSec * slimAudioBytesPerSec;
    return 8 * 1024 * 1024;
  }

  Future<String> _downloadAudioDash({
    required String videoId,
    required String outputDir,
    required YtProgressCallback onProgress,
    required String format,
    required bool extractAudio,
    int estimated = 0,
    int capSec = 0,
    String phase = 'Mengunduh audio (yt-dlp)...',
  }) async {
    final processId = 'a_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';

    final tracker = _ProgressTracker(
      processId: processId,
      phaseLabel: phase,
      onProgress: onProgress,
      estimatedTotalBytes: estimated,
      lockSlimEstimate: extractAudio && estimated > 0,
    );
    final subs = tracker.bind(_dl);

    final custom = Map<String?, String?>.from(_baseArgs);
    custom['--concurrent-fragments'] = '4';
    if (extractAudio && capSec > 0) {
      custom['--postprocessor-args'] =
          'ffmpeg:-ac 1 -ar 16000 -b:a 32k -t $capSec';
    }

    try {
      onProgress(
        YtDownloadProgress(
          progress01: 0.02,
          phase: phase,
          totalBytes: estimated,
        ),
      );
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_audio.%(ext)s',
          format: format,
          extractAudio: extractAudio,
          audioFormat: extractAudio ? 'mp3' : null,
          audioQuality: extractAudio ? 9 : null,
          noPlaylist: true,
          processId: processId,
          customOptions: custom,
        ),
      );
      if (result.status != OperationStatus.success) {
        try {
          final recovered = await _findOutput(
            outputDir,
            preferred: result.outputPath,
            videoId: videoId,
            audioOnly: true,
          );
          final rs = await File(recovered).length();
          if (rs > 1024 && rs <= groqMaxUploadBytes) {
            onProgress(
              YtDownloadProgress(
                progress01: 1,
                phase: 'Audio siap',
                downloadedBytes: rs,
                totalBytes: rs,
              ),
            );
            return recovered;
          }
        } catch (_) {}
        throw Exception(result.errorMessage ?? 'yt-dlp gagal unduh audio');
      }
      final out = await _findOutput(
        outputDir,
        preferred: result.outputPath,
        videoId: videoId,
        audioOnly: true,
      );
      final size = await File(out).length();
      if (extractAudio && size > groqMaxUploadBytes) {
        throw Exception(
          'Audio hasil ${(size / (1024 * 1024)).toStringAsFixed(1)} MB '
          'masih di atas limit Groq ~23 MB. Coba video lebih pendek.',
        );
      }
      onProgress(
        YtDownloadProgress(
          progress01: 1,
          phase: 'Audio siap',
          downloadedBytes: size,
          totalBytes: size,
        ),
      );
      return out;
    } finally {
      await subs.cancel();
    }
  }

  static const _audioExts = {'.m4a', '.mp3', '.opus', '.ogg', '.wav'};

  static bool _isBenignYtDlpWarning(String message) {
    final l = message.toLowerCase();
    if (!l.contains('warning')) return false;
    return l.contains('skipped') ||
        l.contains('missing a url') ||
        l.contains('ios client') ||
        l.contains('falling back');
  }

  Future<String?> _tryRecoverOutput({
    required String outputDir,
    String? preferred,
    required String videoId,
    bool audioOnly = false,
    int minBytes = 2048,
  }) async {
    try {
      final path = await _findOutput(
        outputDir,
        preferred: preferred,
        videoId: videoId,
        audioOnly: audioOnly,
      );
      if (await File(path).length() > minBytes) return path;
    } catch (_) {}
    return null;
  }

  Future<String> _findOutput(
    String dir, {
    String? preferred,
    required String videoId,
    bool audioOnly = false,
  }) async {
    bool okAudio(String path) {
      final ext = p.extension(path).toLowerCase();
      return _audioExts.contains(ext);
    }

    if (preferred != null && preferred.isNotEmpty) {
      final f = File(preferred);
      if (await f.exists() && await f.length() > 1024) {
        if (!audioOnly || okAudio(preferred)) return preferred;
      }
      if (await Directory(preferred).exists()) dir = preferred;
    }

    final folder = Directory(dir);
    if (!await folder.exists()) {
      throw Exception('Output yt-dlp tidak ditemukan');
    }

    final files = await folder
        .list(recursive: audioOnly)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );

    for (final f in files) {
      final ext = p.extension(f.path).toLowerCase();
      if (audioOnly) {
        if (okAudio(f.path) && await f.length() > 1024) return f.path;
      } else if ({'.mp4', '.mkv', '.webm', '.mov'}.contains(ext) &&
          await f.length() > 2048) {
        return f.path;
      }
    }
    if (!audioOnly) {
      for (final f in files) {
        if (await f.length() > 2048) return f.path;
      }
    }
    throw Exception(
      audioOnly
          ? 'Gagal extract MP3 untuk Whisper'
          : 'File hasil yt-dlp kosong',
    );
  }
}

class _ProgressTracker {
  _ProgressTracker({
    required this.processId,
    required this.phaseLabel,
    required this.onProgress,
    this.estimatedTotalBytes = 0,
    this.watchDir,
    this.lockSlimEstimate = false,
  });

  final String processId;
  final String phaseLabel;
  final YtProgressCallback onProgress;
  final int estimatedTotalBytes;
  final String? watchDir;

  /// Jangan ganti total progress dengan ukuran source besar (bestaudio).
  final bool lockSlimEstimate;

  double _pct = 0;
  int _downloaded = 0;
  int _total = 0;
  double _speed = 0;
  String _phase = '';
  DateTime? _lastTick;
  int _lastDownloaded = 0;
  Timer? _poll;

  // [download]  45.2% of ~ 120.00MiB at  2.34MiB/s ETA 00:30
  // [download] 100% of 5.20MiB in 00:03
  static final _lineRe = RegExp(
    r'\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+)\s*(KiB|MiB|GiB|KB|MB|GB|B)'
    r'(?:\s+at\s+(?:([\d.]+)\s*(KiB|MiB|GiB|KB|MB|GB|B)/s|Unknown))?',
    caseSensitive: false,
  );

  _Subs bind(YoutubeDLFlutter dl) {
    _phase = phaseLabel;
    if (_total <= 0 && estimatedTotalBytes > 0) {
      _total = estimatedTotalBytes;
    }
    if (watchDir != null) {
      _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
        unawaited(_pollDir());
      });
    }
    final a = dl.onProgress.listen((p) {
      if (p.processId != processId) return;
      final next = (p.progress / 100).clamp(0.0, 0.99);
      // Jangan turunkan progress (postprocess sering kirim 0 lagi).
      if (next >= _pct) _pct = next;
      if (_total <= 0 && estimatedTotalBytes > 0) {
        _total = estimatedTotalBytes;
      }
      if (_total > 0 && _downloaded < (_pct * _total).round()) {
        _downloaded = (_pct * _total).round();
      }
      if (p.etaInSeconds > 0 && _total > _downloaded) {
        _speed = (_total - _downloaded) / p.etaInSeconds;
      }
      _emit();
    });
    final b = dl.onLog.listen((log) {
      if (log.processId != processId) return;
      _parseLog(log.message);
    });
    return _Subs(
      [a, b],
      onCancel: () {
        _poll?.cancel();
        _poll = null;
      },
    );
  }

  Future<void> _pollDir() async {
    final dir = watchDir;
    if (dir == null) return;
    try {
      final folder = Directory(dir);
      if (!await folder.exists()) return;
      var biggest = 0;
      await for (final e in folder.list(recursive: true)) {
        if (e is! File) continue;
        final len = await e.length();
        if (len > biggest) biggest = len;
      }
      if (biggest <= _downloaded) return;
      final now = DateTime.now();
      if (_lastTick != null) {
        final dt = now.difference(_lastTick!).inMilliseconds / 1000.0;
        if (dt > 0.2) {
          _speed = (biggest - _downloaded) / dt;
        }
      }
      _downloaded = biggest;
      _lastTick = now;
      _lastDownloaded = biggest;
      if (lockSlimEstimate && estimatedTotalBytes > 0) {
        if (_total <= 0) _total = estimatedTotalBytes;
      } else if (biggest > _total) {
        _total = biggest;
      }
      if (_total > 0) {
        _pct = (_downloaded / _total).clamp(0.0, 0.99);
      } else if (_pct < 0.05) {
        _pct = 0.05;
      }
      if (_phase.contains('Menyiapkan') || _phase.contains('Mengunduh')) {
        _phase = phaseLabel;
      }
      _emit();
    } catch (_) {}
  }

  void _parseLog(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('extractaudio') ||
        (lower.contains('destination') && lower.contains('mp3')) ||
        lower.contains('post-process') ||
        lower.contains('merging') ||
        lower.contains('[merger]') ||
        lower.contains('remux') ||
        lower.contains('[videoremuxer]') ||
        lower.contains('[ffmpeg]')) {
      if (lower.contains('extractaudio') || lower.contains('mp3')) {
        _phase = 'Mengompres audio...';
      } else if (lower.contains('remux') || lower.contains('videoremuxer')) {
        _phase = 'Remux potongan...';
      } else if (lower.contains('merging') || lower.contains('[merger]')) {
        _phase = 'Menggabungkan audio+video...';
      } else if (lower.contains('[ffmpeg]')) {
        _phase = 'Proses FFmpeg...';
      } else {
        _phase = 'Memproses file...';
      }
      if (_pct < 0.85) _pct = 0.85;
      _emit();
    }

    final m = _lineRe.firstMatch(message);
    if (m == null) return;
    final pct = double.tryParse(m.group(1) ?? '') ?? _pct * 100;
    final next = (pct / 100).clamp(0.0, 0.99);
    if (next >= _pct) _pct = next;
    final total = _toBytes(m.group(2), m.group(3));
    // Untuk mode slim, total dari log bisa jauh lebih besar (source
    // sebelum compress). Pakai estimasi slim kalau sudah ada.
    if (total != null && total > 0) {
      if (lockSlimEstimate && estimatedTotalBytes > 0) {
        if (_total <= 0) _total = estimatedTotalBytes;
      } else if (total > _total) {
        _total = total;
      }
    }
    final speed = _toBytes(m.group(4), m.group(5));
    if (speed != null && speed > 0) {
      _speed = speed.toDouble();
    }
    if (_total > 0) {
      final fromPct = (_pct * _total).round();
      if (fromPct > _downloaded) _downloaded = fromPct;
    }
    final now = DateTime.now();
    if (_lastTick != null && _downloaded > _lastDownloaded) {
      final dt = now.difference(_lastTick!).inMilliseconds / 1000.0;
      if (dt > 0.2 && _speed <= 0) {
        _speed = (_downloaded - _lastDownloaded) / dt;
      }
    }
    _lastTick = now;
    _lastDownloaded = _downloaded;
    if (!_phase.contains('Remux') &&
        !_phase.contains('Menggabung') &&
        !_phase.contains('FFmpeg') &&
        !_phase.contains('Memproses') &&
        !_phase.contains('Mengompres')) {
      _phase = phaseLabel;
    }
    _emit();
  }

  void _emit() {
    onProgress(
      YtDownloadProgress(
        progress01: _pct <= 0 ? 0.01 : _pct,
        phase: _phase.isEmpty ? phaseLabel : _phase,
        downloadedBytes: _downloaded,
        totalBytes: _total > 0 ? _total : estimatedTotalBytes,
        speedBytesPerSecond: _speed,
      ),
    );
  }

  static int? _toBytes(String? value, String? unit) {
    if (value == null || unit == null) return null;
    final n = double.tryParse(value);
    if (n == null) return null;
    switch (unit.toUpperCase()) {
      case 'B':
        return n.round();
      case 'KIB':
      case 'KB':
        return (n * 1024).round();
      case 'MIB':
      case 'MB':
        return (n * 1024 * 1024).round();
      case 'GIB':
      case 'GB':
        return (n * 1024 * 1024 * 1024).round();
      default:
        return null;
    }
  }
}

class _Subs {
  _Subs(this._subs, {this.onCancel});
  final List<StreamSubscription<dynamic>> _subs;
  final void Function()? onCancel;
  Future<void> cancel() async {
    onCancel?.call();
    for (final s in _subs) {
      await s.cancel();
    }
  }
}
