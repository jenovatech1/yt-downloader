import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// YouTube stream downloader — NewPipe-style progressive + DIY HLS.
///
/// Research (NewPipe YoutubeHttpDataSource / Seal / yt-dlp 2026):
/// - Progressive `videoplayback` needs `range=start-end` **query param** (+ `rn`),
///   not only HTTP `Range` header. Wrong method → throttle hang at a few %.
/// - Match client User-Agent to URL `c=` (ANDROID_VR / IOS / …).
/// - Never use [StreamClient.get] on Android — hangs on many devices.
/// - HLS: parse m3u8 → GET each segment with timeout.
class YtStreamDownloader {
  YtStreamDownloader._();

  static const chunkBytes = 10 * 1024 * 1024;
  static const chunkTimeout = Duration(seconds: 45);
  static const maxRetries = 4;

  /// API dipakai [DownloadService] / [ClipPipeline].
  static Future<void> download(
    StreamInfo stream,
    String path, {
    YoutubeExplode? yt,
    required void Function(int received, int total) onBytes,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    final dest = File(path);
    final downloader = _Downloader();
    try {
      await downloader.download(
        stream,
        dest,
        onProgress: (p) {
          final total = stream.size.totalBytes;
          if (total > 0) {
            onBytes((p * total).round().clamp(0, total), total);
          } else {
            onBytes(0, 1);
          }
        },
        onBytesExact: onBytes,
        refreshStream: refreshStream,
      );
    } finally {
      // yt owned by caller
    }
  }
}

class _Downloader {
  Future<File> download(
    StreamInfo stream,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytesExact,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    if (dest.existsSync()) await dest.delete();
    await dest.parent.create(recursive: true);

    final container = stream.container.name.toLowerCase();
    if (container.contains('m3u8') || container.contains('hls')) {
      return _downloadHls(
        stream,
        dest,
        onProgress: onProgress,
        onBytesExact: onBytesExact,
      );
    }
    return _downloadProgressive(
      stream,
      dest,
      onProgress: onProgress,
      onBytesExact: onBytesExact,
      refreshStream: refreshStream,
    );
  }

  Future<File> _downloadProgressive(
    StreamInfo stream,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytesExact,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    var info = stream;
    var total = info.size.totalBytes;
    if (total <= 0) {
      throw StateError('Ukuran stream tidak diketahui (itag=${info.tag}).');
    }

    final sink = dest.openWrite();
    var got = 0;
    var rn = 0;

    try {
      while (got < total) {
        final from = got;
        final to = (from + YtStreamDownloader.chunkBytes < total
                ? from + YtStreamDownloader.chunkBytes
                : total) -
            1;
        rn++;

        Object? lastError;
        var ok = false;
        for (var attempt = 0;
            attempt < YtStreamDownloader.maxRetries && !ok;
            attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
            if (refreshStream != null && attempt >= 2) {
              try {
                info = await refreshStream();
                final newTotal = info.size.totalBytes;
                if (newTotal > 0) total = newTotal;
              } catch (_) {}
            }
          }

          final client = http.Client();
          try {
            final req = http.Request('GET', _withRange(info.url, from, to, rn));
            req.headers.addAll(_headersFor(info.url));
            final res = await client
                .send(req)
                .timeout(YtStreamDownloader.chunkTimeout);
            if (res.statusCode != 200 && res.statusCode != 206) {
              throw HttpException('HTTP ${res.statusCode} range $from-$to');
            }

            var chunkGot = 0;
            await for (final chunk
                in res.stream.timeout(YtStreamDownloader.chunkTimeout)) {
              if (chunk.isEmpty) continue;
              sink.add(chunk);
              got += chunk.length;
              chunkGot += chunk.length;
              onProgress?.call((got / total).clamp(0.0, 1.0));
              onBytesExact?.call(got, total);
            }
            if (chunkGot <= 0) {
              throw StateError('Chunk kosong $from-$to');
            }
            ok = true;
          } catch (e) {
            lastError = e;
          } finally {
            client.close();
          }
        }

        if (!ok) {
          throw StateError(
            'Gagal chunk $from-$to setelah ${YtStreamDownloader.maxRetries}x: $lastError',
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (got < total) {
      throw StateError('Download tidak lengkap: $got / $total bytes');
    }
    onProgress?.call(1);
    onBytesExact?.call(total, total);
    return dest;
  }

  Future<File> _downloadHls(
    StreamInfo stream,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytesExact,
  }) async {
    final client = http.Client();
    try {
      final playlistUrl = stream.url;
      final playlistRes = await client
          .get(playlistUrl, headers: _headersFor(playlistUrl))
          .timeout(const Duration(seconds: 30));
      if (playlistRes.statusCode != 200) {
        throw HttpException('HLS playlist HTTP ${playlistRes.statusCode}');
      }

      var body = playlistRes.body;
      var base = playlistUrl;
      if (body.contains('#EXT-X-STREAM-INF')) {
        final media = _firstMediaPlaylistUrl(body, playlistUrl);
        if (media == null) {
          throw StateError('HLS master tanpa media playlist');
        }
        final mediaRes = await client
            .get(media, headers: _headersFor(media))
            .timeout(const Duration(seconds: 30));
        if (mediaRes.statusCode != 200) {
          throw HttpException('HLS media HTTP ${mediaRes.statusCode}');
        }
        body = mediaRes.body;
        base = media;
      }

      final segments = _parseSegments(body, base);
      return _writeSegments(
        segments,
        dest,
        client,
        onProgress: onProgress,
        onBytesExact: onBytesExact,
        estimatedTotal: stream.size.totalBytes,
      );
    } finally {
      client.close();
    }
  }

  Future<File> _writeSegments(
    List<Uri> segments,
    File dest,
    http.Client client, {
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytesExact,
    int estimatedTotal = 0,
  }) async {
    if (segments.isEmpty) throw StateError('HLS tanpa segment');
    final sink = dest.openWrite();
    var got = 0;
    try {
      for (var i = 0; i < segments.length; i++) {
        final seg = segments[i];
        Object? lastError;
        var ok = false;
        for (var attempt = 0;
            attempt < YtStreamDownloader.maxRetries && !ok;
            attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
          }
          try {
            final res = await client
                .get(seg, headers: _headersFor(seg))
                .timeout(YtStreamDownloader.chunkTimeout);
            if (res.statusCode != 200) {
              throw HttpException('Segment HTTP ${res.statusCode}');
            }
            if (res.bodyBytes.isEmpty) {
              throw StateError('Segment kosong');
            }
            sink.add(res.bodyBytes);
            got += res.bodyBytes.length;
            ok = true;
          } catch (e) {
            lastError = e;
          }
        }
        if (!ok) {
          throw StateError('Segment $i gagal: $lastError');
        }
        final p = ((i + 1) / segments.length).clamp(0.0, 1.0);
        onProgress?.call(p);
        final totalHint = estimatedTotal > 0 ? estimatedTotal : got;
        onBytesExact?.call(got.clamp(0, totalHint), totalHint);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onProgress?.call(1);
    onBytesExact?.call(got, got);
    return dest;
  }

  Uri _withRange(Uri url, int from, int to, int rn) {
    final q = Map<String, String>.from(url.queryParameters);
    q.remove('range');
    q['range'] = '$from-$to';
    q['rn'] = '$rn';
    return url.replace(queryParameters: q);
  }

  Map<String, String> _headersFor(Uri url) {
    final c = (url.queryParameters['c'] ?? '').toUpperCase();
    return {
      'User-Agent': _uaForClient(c),
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
      'Connection': 'close',
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/',
    };
  }

  String _uaForClient(String c) {
    if (c.contains('ANDROID_VR')) {
      return 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
          '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
    }
    if (c == 'ANDROID' || c.startsWith('ANDROID')) {
      return 'com.google.android.youtube/20.10.38 '
          '(Linux; U; Android 12; US) gzip';
    }
    if (c.contains('IOS')) {
      return 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';
    }
    if (c.contains('TVHTML5') || c.contains('TV')) {
      return 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version';
    }
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  }

  Uri? _firstMediaPlaylistUrl(String master, Uri base) {
    final lines = master.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        for (var j = i + 1; j < lines.length; j++) {
          final next = lines[j].trim();
          if (next.isEmpty || next.startsWith('#')) continue;
          return base.resolve(next);
        }
      }
    }
    return null;
  }

  List<Uri> _parseSegments(String playlist, Uri base) {
    final out = <Uri>[];
    final lines = playlist.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (uriMatch != null) {
          out.add(base.resolve(uriMatch.group(1)!));
        }
        continue;
      }
      if (line.isEmpty || line.startsWith('#')) continue;
      out.add(base.resolve(line));
    }
    return out;
  }

}
