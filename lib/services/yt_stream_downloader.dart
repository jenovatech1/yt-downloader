import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// NewPipe / youtube_explode-compatible progressive + DIY HLS.
///
/// Phone 403 fixes:
/// - `c=ANDROID` → HTTP `Range` header (library rule); else append `&range=`
///   (NewPipe appends; do **not** rebuild query — can break `sig`/`n`).
/// - Minimal headers + CONSENT cookie like [YoutubeHttpClient].
/// - On 403: refresh URL + flip range mode; retry.
class YtStreamDownloader {
  YtStreamDownloader._();

  /// Same chunk size as youtube_explode for throttled streams.
  static const chunkBytes = 10379935;
  static const chunkTimeout = Duration(seconds: 45);
  static const maxRetries = 5;

  static Future<void> download(
    StreamInfo stream,
    String path, {
    YoutubeExplode? yt,
    required void Function(int received, int total) onBytes,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    final dest = File(path);
    final downloader = _Downloader();
    await downloader.download(
      stream,
      dest,
      onBytesExact: onBytes,
      refreshStream: refreshStream,
    );
  }
}

enum _RangeMode { queryParam, header }

class _Downloader {
  Future<File> download(
    StreamInfo stream,
    File dest, {
    void Function(int received, int total)? onBytesExact,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    if (dest.existsSync()) await dest.delete();
    await dest.parent.create(recursive: true);

    final container = stream.container.name.toLowerCase();
    if (container.contains('m3u8') || container.contains('hls')) {
      return _downloadHls(stream, dest, onBytesExact: onBytesExact);
    }
    return _downloadProgressive(
      stream,
      dest,
      onBytesExact: onBytesExact,
      refreshStream: refreshStream,
    );
  }

  Future<File> _downloadProgressive(
    StreamInfo stream,
    File dest, {
    void Function(int received, int total)? onBytesExact,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    var info = stream;
    var total = info.size.totalBytes;
    if (total <= 0) {
      throw StateError('Ukuran stream tidak diketahui (itag=${info.tag}).');
    }

    // Match youtube_explode: ANDROID → header; else query param.
    var mode = _preferredMode(info.url);
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
            await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
          }

          // 403 → refresh URL ASAP + flip range mode.
          if (attempt > 0 || lastError.toString().contains('403')) {
            if (refreshStream != null && attempt >= 1) {
              try {
                info = await refreshStream();
                final newTotal = info.size.totalBytes;
                if (newTotal > 0) total = newTotal;
                mode = _preferredMode(info.url);
              } catch (_) {}
            }
            if (attempt >= 1) {
              mode = mode == _RangeMode.header
                  ? _RangeMode.queryParam
                  : _RangeMode.header;
            }
          }

          final client = http.Client();
          try {
            final req = _buildRequest(info.url, from, to, rn, mode);
            final res =
                await client.send(req).timeout(YtStreamDownloader.chunkTimeout);
            if (res.statusCode == 403) {
              throw HttpException('HTTP 403 range $from-$to mode=$mode');
            }
            if (res.statusCode != 200 && res.statusCode != 206) {
              throw HttpException(
                'HTTP ${res.statusCode} range $from-$to mode=$mode',
              );
            }

            var chunkGot = 0;
            await for (final chunk
                in res.stream.timeout(YtStreamDownloader.chunkTimeout)) {
              if (chunk.isEmpty) continue;
              sink.add(chunk);
              got += chunk.length;
              chunkGot += chunk.length;
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
    onBytesExact?.call(total, total);
    return dest;
  }

  _RangeMode _preferredMode(Uri url) {
    final c = (url.queryParameters['c'] ?? '').toUpperCase();
    // Exact youtube_explode rule (only exact ANDROID, not ANDROID_VR).
    if (c == 'ANDROID') return _RangeMode.header;
    return _RangeMode.queryParam;
  }

  http.Request _buildRequest(
    Uri url,
    int from,
    int to,
    int rn,
    _RangeMode mode,
  ) {
    late final http.Request req;
    if (mode == _RangeMode.header) {
      // Strip any existing range query; use header only.
      var s = url.toString();
      s = s.replaceAll(RegExp(r'[&?]range=[^&]*'), '');
      s = s.replaceAll(RegExp(r'[&?]rn=[^&]*'), '');
      if (s.contains('?&')) s = s.replaceFirst('?&', '?');
      req = http.Request('GET', Uri.parse(s));
      req.headers['Range'] = 'bytes=$from-$to';
    } else {
      // NewPipe: append &range= &rn= without rebuilding query (preserves sig/n).
      var s = url.toString();
      s = s.replaceAll(RegExp(r'&range=[^&]*'), '');
      s = s.replaceAll(RegExp(r'&rn=[^&]*'), '');
      s = '$s&range=$from-$to&rn=$rn';
      req = http.Request('GET', Uri.parse(s));
    }

    final c = (url.queryParameters['c'] ?? '').toUpperCase();
    req.headers.addAll({
      // YoutubeHttpClient defaults — needed on some mobile CDNs.
      'user-agent': _uaForClient(c),
      'cookie': 'CONSENT=YES+cb',
      'accept': '*/*',
      'accept-language': 'en-US,en;q=0.5',
    });
    return req;
  }

  String _uaForClient(String c) {
    if (c.contains('ANDROID_VR')) {
      // Match common VR UA used by extractors (client payload has no UA).
      return 'com.google.android.apps.youtube.vr.oculus/1.56.21 '
          '(Linux; U; Android 12; eureka-user Build/SQ3A.220605.009.A1) gzip';
    }
    if (c == 'ANDROID') {
      return 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
    }
    if (c.contains('IOS')) {
      return 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';
    }
    if (c.contains('TV')) {
      return 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)';
    }
    // Same as YoutubeHttpClient.defaultHeaders
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/96.0.4664.18 Safari/537.36';
  }

  Future<File> _downloadHls(
    StreamInfo stream,
    File dest, {
    void Function(int received, int total)? onBytesExact,
  }) async {
    final client = http.Client();
    try {
      final playlistUrl = stream.url;
      final headers = {
        'user-agent': _uaForClient(
          (playlistUrl.queryParameters['c'] ?? 'IOS').toUpperCase(),
        ),
        'cookie': 'CONSENT=YES+cb',
        'accept': '*/*',
      };
      final playlistRes = await client
          .get(playlistUrl, headers: headers)
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
            .get(media, headers: headers)
            .timeout(const Duration(seconds: 30));
        if (mediaRes.statusCode != 200) {
          throw HttpException('HLS media HTTP ${mediaRes.statusCode}');
        }
        body = mediaRes.body;
        base = media;
      }

      final segments = _parseSegments(body, base);
      if (segments.isEmpty) throw StateError('HLS tanpa segment');

      final sink = dest.openWrite();
      var got = 0;
      final estimated = stream.size.totalBytes;
      try {
        for (var i = 0; i < segments.length; i++) {
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
                  .get(segments[i], headers: headers)
                  .timeout(YtStreamDownloader.chunkTimeout);
              if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
                throw HttpException('Segment HTTP ${res.statusCode}');
              }
              sink.add(res.bodyBytes);
              got += res.bodyBytes.length;
              ok = true;
            } catch (e) {
              lastError = e;
            }
          }
          if (!ok) throw StateError('Segment $i gagal: $lastError');
          final totalHint = estimated > 0 ? estimated : got;
          onBytesExact?.call(got.clamp(0, totalHint), totalHint);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      onBytesExact?.call(got, got);
      return dest;
    } finally {
      client.close();
    }
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
    for (final raw in playlist.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (uriMatch != null) out.add(base.resolve(uriMatch.group(1)!));
        continue;
      }
      if (line.isEmpty || line.startsWith('#')) continue;
      out.add(base.resolve(line));
    }
    return out;
  }
}
