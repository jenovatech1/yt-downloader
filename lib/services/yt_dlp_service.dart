import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

  /// Audio untuk Whisper: mono 16kHz 32kbps (sama desktop Klippod).
  /// Cap ~85 menit biar tetap di bawah limit upload Groq ~23 MB.
  static const groqMaxUploadBytes = 23 * 1024 * 1024;
  static const transcribeMaxSeconds = 85 * 60;
  static const slimAudioBytesPerSec = 4000; // 32 kbps

  Future<String> downloadAudio({
    required String videoId,
    required String outputDir,
    required YtProgressCallback onProgress,
    Duration? videoDuration,
    bool forTranscribe = true,
  }) async {
    await ensureReady();
    await Directory(outputDir).create(recursive: true);

    final processId = 'a_${videoId}_${DateTime.now().millisecondsSinceEpoch}';
    final url = 'https://www.youtube.com/watch?v=$videoId';
    final durSec = videoDuration?.inSeconds ?? 0;
    final capSec = forTranscribe
        ? (durSec > 0
            ? math.min(durSec, transcribeMaxSeconds)
            : transcribeMaxSeconds)
        : (durSec > 0 ? durSec : 0);
    final estimated = forTranscribe
        ? (capSec > 0 ? capSec * slimAudioBytesPerSec : 8 * 1024 * 1024)
        : 0;

    final tracker = _ProgressTracker(
      processId: processId,
      phaseLabel: 'Mengunduh audio...',
      onProgress: onProgress,
      estimatedTotalBytes: estimated,
      watchDir: outputDir,
    );
    final subs = tracker.bind(_dl);

    final custom = Map<String?, String?>.from(_baseArgs);
    if (forTranscribe) {
      // FFmpeg post: mono / 16kHz / 32k ? file kecil untuk Whisper.
      custom['--postprocessor-args'] = 'ffmpeg:-ac 1 -ar 16000 -b:a 32k';
      if (durSec > transcribeMaxSeconds) {
        custom['--download-sections'] =
            '*0-${transcribeMaxSeconds.toDouble()}';
      }
    }

    try {
      onProgress(
        YtDownloadProgress(
          progress01: 0.02,
          phase: forTranscribe
              ? 'Menyiapkan audio slim (32kbps)...'
              : 'Menyiapkan audio...',
          totalBytes: estimated,
        ),
      );
      final result = await _dl.download(
        DownloadRequest(
          url: url,
          outputPath: outputDir,
          outputTemplate: '%(id)s_audio.%(ext)s',
          format: 'bestaudio/best',
          extractAudio: true,
          audioFormat: forTranscribe ? 'mp3' : 'm4a',
          audioQuality: forTranscribe ? 9 : 5,
          noPlaylist: true,
          processId: processId,
          customOptions: custom,
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
      if (forTranscribe && size > groqMaxUploadBytes) {
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
    this.watchDir,
  });

  final String processId;
  final String phaseLabel;
  final YtProgressCallback onProgress;
  final int estimatedTotalBytes;
  final String? watchDir;

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
    return _Subs([a, b], onCancel: () {
      _poll?.cancel();
      _poll = null;
    });
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
      if (_total > 0) {
        _pct = (_downloaded / _total).clamp(0.0, 0.95);
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
        lower.contains('merging')) {
      _phase = 'Mengompres audio...';
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
      if (estimatedTotalBytes <= 0 || total <= estimatedTotalBytes * 1.5) {
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
    _phase = phaseLabel;
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
