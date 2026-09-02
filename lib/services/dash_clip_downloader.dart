import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'yt_dlp_service.dart';

/// Unduh potongan via DASH fragment paralel — sama prinsip yt-dlp full download.
/// JANGAN pakai yt-dlp --download-sections (itu paksa FFmpeg = linear ~0.3 Mbps).
class DashClipDownloader {
  DashClipDownloader._();
  static final DashClipDownloader instance = DashClipDownloader._();

  static const parallelFragments = 16;
  static const chunkTimeout = Duration(seconds: 45);
  static const maxRetries = 5;

  static const _defaultHeaders = {
    'user-agent':
        'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
    'accept': '*/*',
    'cookie': 'CONSENT=YES+cb',
  };

  ({Map<String, dynamic>? video, Map<String, dynamic>? audio}) pickStreams(
    Map<String, dynamic> info, {
    int maxHeight = 1080,
  }) {
    final preferredAudioLanguage = _preferredAudioLanguage(info);
    final fromRequested = _pickFromList(
      info['requested_formats'],
      maxHeight: maxHeight,
      preferredAudioLanguage: preferredAudioLanguage,
    );
    if (fromRequested.video != null) {
      return fromRequested;
    }

    final fromFormats = _pickFromList(
      info['formats'],
      maxHeight: maxHeight,
      preferredAudioLanguage: preferredAudioLanguage,
    );
    if (fromFormats.video != null) {
      return fromFormats;
    }
    return (video: null, audio: null);
  }

  bool hasSegmentedStreams(Map<String, dynamic> info, {int maxHeight = 1080}) {
    final streams = pickStreams(info, maxHeight: maxHeight);
    return streams.video != null && streams.audio != null;
  }

  ({Map<String, dynamic>? video, Map<String, dynamic>? audio}) _pickFromList(
    Object? raw, {
    required int maxHeight,
    String? preferredAudioLanguage,
  }) {
    if (raw is! List || raw.isEmpty) {
      return (video: null, audio: null);
    }
    Map<String, dynamic>? bestV;
    Map<String, dynamic>? bestA;
    var bestVScore = -1;
    var bestAScore = -1;
    for (final f in raw) {
      if (f is! Map) continue;
      final m = Map<String, dynamic>.from(f);
      if (!_isSegmentedFormat(m)) continue;

      final vcodec = (m['vcodec'] as String?) ?? 'none';
      final acodec = (m['acodec'] as String?) ?? 'none';
      final format = '${m['format'] ?? ''}'.toLowerCase();
      final formatNote = '${m['format_note'] ?? ''}'.toLowerCase();
      final language = '${m['language'] ?? ''}'.toLowerCase();
      final audioExt = '${m['audio_ext'] ?? ''}'.toLowerCase();
      final videoExt = '${m['video_ext'] ?? ''}'.toLowerCase();
      final h = (m['height'] as num?)?.toInt() ?? 0;
      final abr = (m['abr'] as num?)?.toInt() ?? 0;
      final tbr = (m['tbr'] as num?)?.toInt() ?? 0;
      final isAudioOnly =
          vcodec == 'none' &&
          (acodec != 'none' ||
              (audioExt.isNotEmpty && audioExt != 'none') ||
              format.contains('audio only'));
      final isVideoOnly =
          !isAudioOnly &&
          acodec == 'none' &&
          (vcodec != 'none' || (videoExt.isNotEmpty && videoExt != 'none'));

      if (isVideoOnly && h <= maxHeight) {
        final codec = vcodec.toLowerCase();
        final codecScore = codec.contains('avc') || codec.contains('h264')
            ? 10000
            : 0;
        final score = codecScore + h;
        if (score > bestVScore) {
          bestV = m;
          bestVScore = score;
        }
      }
      if (isAudioOnly) {
        final isMp4Audio =
            acodec.toLowerCase().contains('mp4a') || audioExt.contains('mp4');
        final codecScore = isMp4Audio ? 10000 : 0;
        final label = '$format $formatNote';
        final originalScore = label.contains('original') ? 1000000 : 0;
        final languageScore = _sameLanguage(language, preferredAudioLanguage)
            ? 500000
            : 0;
        final descriptionPenalty =
            label.contains('description') || label.contains('descriptive')
            ? 200000
            : 0;
        final score =
            originalScore +
            languageScore +
            codecScore +
            abr +
            tbr -
            descriptionPenalty;
        if (score > bestAScore) {
          bestA = m;
          bestAScore = score;
        }
      }
    }
    if (bestV != null && bestA != null) return (video: bestV, audio: bestA);
    return (video: bestV, audio: bestA);
  }

  String? _preferredAudioLanguage(Map<String, dynamic> info) {
    final requested = info['requested_formats'];
    if (requested is List) {
      String? fallback;
      for (final raw in requested) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final vcodec = '${m['vcodec'] ?? 'none'}';
        final language = '${m['language'] ?? ''}'.trim();
        if (vcodec != 'none' || language.isEmpty) continue;
        final note = '${m['format_note'] ?? ''} ${m['format'] ?? ''}'
            .toLowerCase();
        if (note.contains('original')) return language;
        fallback ??= language;
      }
      if (fallback != null) return fallback;
    }
    for (final key in const ['original_language', 'language']) {
      final value = '${info[key] ?? ''}'.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  bool _sameLanguage(String language, String? preferred) {
    if (language.isEmpty || preferred == null || preferred.isEmpty) {
      return false;
    }
    String base(String value) =>
        value.toLowerCase().split(RegExp('[-_]')).first;
    return base(language) == base(preferred);
  }

  bool _isSegmentedFormat(Map<String, dynamic> m) {
    final p = '${m['protocol'] ?? ''}'.toLowerCase();
    final fragments = m['fragments'];
    return p.contains('dash') ||
        p.contains('m3u8') ||
        p.contains('hls') ||
        (fragments is List && fragments.isNotEmpty);
  }

  List<DashFragmentInfo> fragmentsFromFormat(Map<String, dynamic> fmt) {
    final raw = fmt['fragments'];
    if (raw is! List || raw.isEmpty) return const [];

    final base =
        (fmt['fragment_base_url'] as String?) ?? (fmt['url'] as String?);
    if (base == null || base.isEmpty) return const [];

    final out = <DashFragmentInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final path = (m['path'] as String?) ?? (m['url'] as String?);
      if (path == null || path.isEmpty) continue;
      final uri = path.startsWith('http') ? path : '$base$path';
      final dur = (m['duration'] as num?)?.toDouble();
      out.add(
        DashFragmentInfo(uri: uri, durationSec: dur, isInit: out.isEmpty),
      );
    }
    return out;
  }

  Map<String, String> headersFromFormat(Map<String, dynamic>? fmt) {
    if (fmt == null) return Map.from(_defaultHeaders);
    final raw = fmt['http_headers'];
    if (raw is Map) {
      final out = <String, String>{};
      raw.forEach((k, v) {
        if (k != null && v != null) out[k.toString()] = v.toString();
      });
      if (out.isNotEmpty) return out;
    }
    return Map.from(_defaultHeaders);
  }

  Future<String> downloadSection({
    required Map<String, dynamic> videoFmt,
    Map<String, dynamic>? audioFmt,
    required double sectionStart,
    required double sectionEnd,
    required String outputDir,
    required double videoDurationSec,
    required YtProgressCallback onProgress,
    int estimatedTotalBytes = 0,
  }) async {
    await Directory(outputDir).create(recursive: true);
    final vFrags = await _fragmentsForFormat(videoFmt);
    if (vFrags.isEmpty) {
      throw StateError('Format video tanpa segment');
    }

    if (audioFmt == null) {
      throw StateError('Stream audio tidak ditemukan');
    }
    final aFrags = await _fragmentsForFormat(audioFmt);
    if (aFrags.isEmpty) {
      throw StateError('Stream audio tanpa segment');
    }
    final vPath = p.join(outputDir, 'dash_v.raw');
    final aPath = p.join(outputDir, 'dash_a.raw');
    final vHeaders = headersFromFormat(videoFmt);
    final aHeaders = headersFromFormat(audioFmt);

    final vPick = _pickFragments(
      vFrags,
      sectionStart,
      sectionEnd,
      videoDurationSec,
    );
    final aPick = _pickFragments(
      aFrags,
      sectionStart,
      sectionEnd,
      videoDurationSec,
    );

    final vEst = _estimateBytes(
      videoFmt,
      vPick.media.length,
      vFrags.length,
      sectionStart,
      sectionEnd,
      videoDurationSec,
      estimatedTotalBytes ~/ 2,
    );
    final aEst = _estimateBytes(
      audioFmt,
      aPick.media.length,
      aFrags.length,
      sectionStart,
      sectionEnd,
      videoDurationSec,
      estimatedTotalBytes ~/ 2,
    );
    final totalEst = vEst + aEst;

    var vGot = 0;
    var aGot = 0;
    final meter = _ByteSpeedMeter();

    void report(String phase) {
      final got = vGot + aGot;
      onProgress(
        YtDownloadProgress(
          progress01: (0.05 + 0.75 * (got / (totalEst > 0 ? totalEst : 1)))
              .clamp(0.05, 0.80),
          phase: phase,
          downloadedBytes: got,
          totalBytes: totalEst > 0 ? totalEst : got,
          speedBytesPerSecond: meter.tick(got),
        ),
      );
    }

    report('Mengunduh segment potongan...');

    final client = http.Client();
    try {
      await Future.wait([
        _downloadFragmentSet(
          client: client,
          frags: vPick.all,
          destPath: vPath,
          headers: vHeaders,
          onGot: (n) {
            vGot = n;
            report('Mengunduh segment potongan...');
          },
        ),
        _downloadFragmentSet(
          client: client,
          frags: aPick.all,
          destPath: aPath,
          headers: aHeaders,
          onGot: (n) {
            aGot = n;
            report('Mengunduh segment potongan...');
          },
        ),
      ]);
    } finally {
      client.close();
    }

    onProgress(
      YtDownloadProgress(
        progress01: 0.82,
        phase: 'Merapikan potongan...',
        downloadedBytes: vGot + aGot,
        totalBytes: totalEst,
        speedBytesPerSecond: meter.speed,
      ),
    );

    final trimStart = (sectionStart - vPick.rangeStartSec).clamp(
      0.0,
      sectionEnd,
    );
    return YtDlpService.instance.remuxLocalClip(
      videoPath: vPath,
      audioPath: aPath,
      outputDir: outputDir,
      trimStartSec: trimStart,
      audioTrimStartSec: (sectionStart - aPick.rangeStartSec).clamp(
        0.0,
        sectionEnd,
      ),
      durationSec: sectionEnd - sectionStart,
      onProgress: onProgress,
    );
  }

  _FragPick _pickFragments(
    List<DashFragmentInfo> frags,
    double start,
    double end,
    double durSec,
  ) {
    if (frags.isEmpty) {
      throw StateError('Tidak ada fragment');
    }

    final init = frags.where((f) => f.isInit).toList();
    final media = frags.where((f) => !f.isInit).toList();
    if (media.isEmpty) {
      return _FragPick(all: init, media: const [], rangeStartSec: 0);
    }

    final fallbackSegDur = durSec > 0 ? durSec / media.length : 5.0;
    final tStart = (start - 2.0).clamp(0.0, durSec);
    final tEnd = (end + 2.0).clamp(tStart, durSec);

    final picked = <DashFragmentInfo>[...init];
    var rangeStart = 0.0;
    var firstPicked = false;
    var cursor = 0.0;
    for (final f in media) {
      final d = f.durationSec ?? fallbackSegDur;
      final segStart = cursor;
      final segEnd = cursor + d;
      cursor = segEnd;
      if (segEnd > tStart && segStart < tEnd) {
        if (!firstPicked) {
          rangeStart = segStart;
          firstPicked = true;
        }
        picked.add(f);
      }
    }
    if (!firstPicked) {
      picked.add(media.first);
      rangeStart = 0;
    }
    return _FragPick(
      all: picked,
      media: picked.where((f) => !f.isInit).toList(),
      rangeStartSec: rangeStart,
    );
  }

  Future<List<DashFragmentInfo>> _fragmentsForFormat(
    Map<String, dynamic> fmt,
  ) async {
    final inline = fragmentsFromFormat(fmt);
    if (inline.isNotEmpty) return inline;

    final protocol = '${fmt['protocol'] ?? ''}'.toLowerCase();
    final rawUrl = fmt['url'] as String?;
    if (rawUrl == null ||
        rawUrl.isEmpty ||
        !(protocol.contains('m3u8') || protocol.contains('hls'))) {
      return const [];
    }

    final client = http.Client();
    try {
      var playlistUri = Uri.parse(rawUrl);
      var response = await client
          .get(playlistUri, headers: headersFromFormat(fmt))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('Playlist HTTP ${response.statusCode}');
      }
      var body = response.body;
      if (body.contains('#EXT-X-STREAM-INF')) {
        final child = _firstPlaylistUri(body, playlistUri);
        if (child == null) throw StateError('HLS master tanpa media');
        playlistUri = child;
        response = await client
            .get(playlistUri, headers: headersFromFormat(fmt))
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw HttpException('HLS media HTTP ${response.statusCode}');
        }
        body = response.body;
      }
      return _parseHlsSegments(body, playlistUri);
    } finally {
      client.close();
    }
  }

  Uri? _firstPlaylistUri(String body, Uri base) {
    final lines = body.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].trim().startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j].trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        return base.resolve(line);
      }
    }
    return null;
  }

  List<DashFragmentInfo> _parseHlsSegments(String body, Uri base) {
    final lines = body.split('\n');
    final out = <DashFragmentInfo>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match != null) {
          out.add(
            DashFragmentInfo(
              uri: base.resolve(match.group(1)!).toString(),
              durationSec: 0,
              isInit: true,
            ),
          );
        }
        continue;
      }
      if (!line.startsWith('#EXTINF:')) continue;
      final duration =
          double.tryParse(line.substring(8).split(',').first.trim()) ?? 6;
      for (var j = i + 1; j < lines.length; j++) {
        final path = lines[j].trim();
        if (path.isEmpty || path.startsWith('#')) continue;
        out.add(
          DashFragmentInfo(
            uri: base.resolve(path).toString(),
            durationSec: duration,
          ),
        );
        break;
      }
    }
    return out;
  }

  int _estimateBytes(
    Map<String, dynamic> fmt,
    int pickedCount,
    int totalCount,
    double start,
    double end,
    double durSec,
    int fallback,
  ) {
    final fs =
        (fmt['filesize'] as num?)?.toInt() ??
        (fmt['filesize_approx'] as num?)?.toInt();
    if (fs != null && fs > 0 && totalCount > 0) {
      return ((fs * pickedCount / totalCount) * 1.1).round().clamp(
        256 * 1024,
        fs,
      );
    }
    if (fs != null && fs > 0 && durSec > 0) {
      return ((fs * (end - start) / durSec) * 1.1).round().clamp(
        256 * 1024,
        fs,
      );
    }
    return fallback > 0 ? fallback : 5 * 1024 * 1024;
  }

  Future<void> _downloadFragmentSet({
    required http.Client client,
    required List<DashFragmentInfo> frags,
    required String destPath,
    required Map<String, String> headers,
    required void Function(int got) onGot,
  }) async {
    final file = File(destPath);
    if (await file.exists()) await file.delete();
    final sink = file.openWrite();
    final buffers = List<List<int>?>.filled(frags.length, null);
    var next = 0;
    var totalGot = 0;

    try {
      await Future.wait(
        List.generate(parallelFragments.clamp(1, frags.length), (_) async {
          while (true) {
            final i = next++;
            if (i >= frags.length) return;
            buffers[i] = await _fetchBytes(
              client,
              Uri.parse(frags[i].uri),
              headers,
            );
            var partial = 0;
            for (final b in buffers) {
              if (b != null) partial += b.length;
            }
            totalGot = partial;
            onGot(totalGot);
          }
        }),
      );
      for (final b in buffers) {
        if (b == null || b.isEmpty) throw StateError('Fragment DASH kosong');
        sink.add(b);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onGot(totalGot);
  }

  Future<List<int>> _fetchBytes(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    Object? last;
    for (var a = 0; a < maxRetries; a++) {
      if (a > 0) await Future<void>.delayed(Duration(milliseconds: 350 * a));
      try {
        final res = await client
            .get(uri, headers: headers)
            .timeout(chunkTimeout);
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
          throw HttpException('HTTP ${res.statusCode}');
        }
        return res.bodyBytes;
      } catch (e) {
        last = e;
      }
    }
    throw StateError('Fragment gagal: $last');
  }
}

class DashFragmentInfo {
  const DashFragmentInfo({
    required this.uri,
    this.durationSec,
    this.isInit = false,
  });
  final String uri;
  final double? durationSec;
  final bool isInit;
}

class _FragPick {
  const _FragPick({
    required this.all,
    required this.media,
    required this.rangeStartSec,
  });
  final List<DashFragmentInfo> all;
  final List<DashFragmentInfo> media;
  final double rangeStartSec;
}

class _ByteSpeedMeter {
  int _lastBytes = 0;
  int _lastMs = 0;
  double speed = 0;

  double tick(int bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastMs > 0) {
      final dt = (now - _lastMs) / 1000.0;
      if (dt >= 0.25) {
        speed = ((bytes - _lastBytes) / dt).clamp(0, double.infinity);
        _lastBytes = bytes;
        _lastMs = now;
      }
    } else {
      _lastBytes = bytes;
      _lastMs = now;
    }
    return speed;
  }
}
