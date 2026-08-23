import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:path/path.dart' as p;

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
    final init = await _dl.initialize(
      enableFFmpeg: true,
      enableAria2c: false,
    );
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
    return 'bestvideo[height<=$h][ext=mp4]+bestaudio[ext=m4a]/'
        'bestvideo[height<=$h]+bestaudio/'
        'best[height<=$h]/best';
  }

  Map<String?, String?> get _baseArgs => {
        '--extractor-args': 'youtube:player_client=default,-android_sdkless',
        '--merge-output-format': 'mp4',
        '--retries': '15',
        '--fragment-retries': '15',
      };

  Future<String> downloadVideo({
    required String videoId,
    required int height,
    required String outputDir,
    required YtProgressCallback onProgress,
    int estimatedTotalBytes = 0,
    double? sectionStart,
    double? sectionEnd,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId =
        'v_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final custom = Map<String?, String?>.from(_baseArgs);
    if (sectionStart != null &&
        sectionEnd != null &&
        sectionEnd > sectionStart) {
      custom['--download-sections'] =
          '*${sectionStart.toStringAsFixed(3)}-${sectionEnd.toStringAsFixed(3)}';
      custom['--force-keyframes-at-cuts'] = 'true';
    }

    final tracker = _ProgressTracker(
      processId: processId,
      phaseLabel: 'Mengunduh (yt-dlp)...',
      estimatedTotalBytes: estimatedTotalBytes,
      onProgress: onProgress,
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
          outputTemplate: sectionStart != null
              ? '%(id)s_clip_%(autonumber)s.%(ext)s'
              : '%(id)s_%(height)sp.%(ext)s',
          format: formatForHeight(height),
          noPlaylist: true,
          processId: processId,
          customOptions: custom,
        ),
      );
      if (result.status != OperationStatus.success) {
        throw Exception(result.errorMessage ?? 'yt-dlp gagal unduh video');
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

  Future<String> downloadAudio({
    required String videoId,
    required String outputDir,
    required YtProgressCallback onProgress,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId = 'a_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final tracker = _ProgressTracker(
      processId: processId,
      phaseLabel: 'Mengunduh audio...',
      onProgress: onProgress,
    );
    final subs = tracker.bind(_dl);

    try {
      onProgress(
        const YtDownloadProgress(
          progress01: 0.02,
          phase: 'Menyiapkan audio...',
        ),
      );
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_audio.%(ext)s',
          format: 'bestaudio/best',
          extractAudio: true,
          audioFormat: 'm4a',
          audioQuality: 5,
          noPlaylist: true,
          processId: processId,
          customOptions: {..._baseArgs},
        ),
      );
      if (result.status != OperationStatus.success) {
        throw Exception(result.errorMessage ?? 'yt-dlp gagal unduh audio');
      }
      final out = await _findOutput(
        outputDir,
        preferred: result.outputPath,
        videoId: videoId,
        audioOnly: true,
      );
      final size = await File(out).length();
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

  Future<String> _findOutput(
    String dir, {
    String? preferred,
    required String videoId,
    bool audioOnly = false,
  }) async {
    if (preferred != null && preferred.isNotEmpty) {
      final f = File(preferred);
      if (await f.exists() && await f.length() > 2048) return preferred;
      if (await Directory(preferred).exists()) dir = preferred;
    }

    final folder = Directory(dir);
    if (!await folder.exists()) {
      throw Exception('Output yt-dlp tidak ditemukan');
    }

    final files = await folder
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );

    for (final f in files) {
      final name = p.basename(f.path).toLowerCase();
      final ext = p.extension(name);
      if (audioOnly) {
        if ({'.m4a', '.mp3', '.opus', '.webm', '.ogg'}.contains(ext) &&
            await f.length() > 1024) {
          return f.path;
        }
      } else if ({'.mp4', '.mkv', '.webm', '.mov'}.contains(ext) &&
          await f.length() > 2048) {
        return f.path;
      }
    }
    for (final f in files) {
      if (await f.length() > 2048) return f.path;
    }
    throw Exception('File hasil yt-dlp kosong');
  }
}

class _ProgressTracker {
  _ProgressTracker({
    required this.processId,
    required this.phaseLabel,
    required this.onProgress,
    this.estimatedTotalBytes = 0,
  });

  final String processId;
  final String phaseLabel;
  final YtProgressCallback onProgress;
  final int estimatedTotalBytes;

  double _pct = 0;
  int _downloaded = 0;
  int _total = 0;
  double _speed = 0;
  DateTime? _lastTick;
  int _lastDownloaded = 0;

  // [download]  45.2% of ~ 120.00MiB at  2.34MiB/s ETA 00:30
  static final _lineRe = RegExp(
    r'\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+)\s*(KiB|MiB|GiB|KB|MB|GB|B)'
    r'(?:\s+at\s+(?:([\d.]+)\s*(KiB|MiB|GiB|KB|MB|GB|B)/s|Unknown))?',
    caseSensitive: false,
  );

  _Subs bind(YoutubeDLFlutter dl) {
    final a = dl.onProgress.listen((p) {
      if (p.processId != processId) return;
      _pct = (p.progress / 100).clamp(0.0, 0.99);
      if (_total <= 0 && estimatedTotalBytes > 0) {
        _total = estimatedTotalBytes;
      }
      if (_total > 0) {
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
    return _Subs([a, b]);
  }

  void _parseLog(String message) {
    final m = _lineRe.firstMatch(message);
    if (m == null) return;
    final pct = double.tryParse(m.group(1) ?? '') ?? _pct * 100;
    _pct = (pct / 100).clamp(0.0, 0.99);
    final total = _toBytes(m.group(2), m.group(3));
    if (total != null && total > 0) _total = total;
    final speed = _toBytes(m.group(4), m.group(5));
    if (speed != null && speed > 0) {
      _speed = speed.toDouble();
    }
    if (_total > 0) {
      _downloaded = (_pct * _total).round();
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
    _emit();
  }

  void _emit() {
    onProgress(
      YtDownloadProgress(
        progress01: _pct <= 0 ? 0.01 : _pct,
        phase: phaseLabel,
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
  _Subs(this._subs);
  final List<StreamSubscription<dynamic>> _subs;
  Future<void> cancel() async {
    for (final s in _subs) {
      await s.cancel();
    }
  }
}
