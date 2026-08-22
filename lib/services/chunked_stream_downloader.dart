import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Unduh stream YouTube dengan Range chunk (~10MB), sama seperti
/// `YoutubeHttpClient._getStream` di youtube_explode — wajib untuk stream
/// yang `isThrottled` (kalau unduh full-connection, macet di beberapa %).
class ChunkedStreamDownloader {
  static const _chunkBytes = 10379935; // sama library
  static const _ua =
      'com.google.android.youtube/19.29.1 (Linux; U; Android 14) gzip';
  static const _chunkTimeout = Duration(seconds: 45);

  static Future<void> download(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? ytForRefresh,
  }) async {
    final total = info.size.totalBytes;
    if (total <= 0) {
      // Tanpa ukuran: fallback ke library stream (muxed kecil biasanya OK).
      await _viaExplodeStream(info, path, onBytes: onBytes, yt: ytForRefresh);
      return;
    }

    final file = File(path);
    if (await file.exists()) await file.delete();
    final raf = await file.open(mode: FileMode.write);
    var received = 0;
    var url = info.url;
    final client = http.Client();

    try {
      while (received < total) {
        final from = received;
        final span = info.isThrottled
            ? math.min(_chunkBytes, total - received)
            : (total - received);
        final to = from + span - 1;

        Object? lastErr;
        var ok = false;
        for (var attempt = 1; attempt <= 4; attempt++) {
          try {
            final req = http.Request('GET', _requestUri(url, from, to));
            req.headers[HttpHeaders.userAgentHeader] = _ua;
            req.headers[HttpHeaders.acceptHeader] = '*/*';
            if (_isAndroidClient(url)) {
              req.headers[HttpHeaders.rangeHeader] = 'bytes=$from-$to';
            }

            final streamed = await client.send(req).timeout(_chunkTimeout);
            if (streamed.statusCode == 403 && ytForRefresh != null) {
              final fresh = await ytForRefresh.videos.streamsClient
                  .getManifest(info.videoId.value);
              final match = fresh.streams.cast<StreamInfo?>().firstWhere(
                    (s) => s?.tag == info.tag,
                    orElse: () => null,
                  );
              if (match != null) {
                url = match.url;
                lastErr = Exception('403, refresh URL');
                continue;
              }
            }
            if (streamed.statusCode != 200 && streamed.statusCode != 206) {
              throw Exception('HTTP ${streamed.statusCode} range $from-$to');
            }

            final bytes = await streamed.stream
                .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
                .timeout(_chunkTimeout);
            if (bytes.isEmpty) {
              throw Exception('Chunk kosong $from-$to');
            }
            await raf.setPosition(from);
            await raf.writeFrom(bytes);
            received = from + bytes.length;
            onBytes(received, total);
            ok = true;
            break;
          } catch (e) {
            lastErr = e;
            await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
          }
        }
        if (!ok) {
          throw Exception('Gagal unduh chunk @$from: $lastErr');
        }
      }
    } finally {
      await raf.close();
      client.close();
    }

    if (received < (total * 0.95).round()) {
      throw Exception('Download terpotong ($received / $total)');
    }
  }

  static bool _isAndroidClient(Uri url) {
    final c = url.queryParameters['c']?.toUpperCase() ?? '';
    return c.startsWith('ANDROID');
  }

  static Uri _requestUri(Uri url, int from, int to) {
    if (_isAndroidClient(url)) {
      // Range di header; hapus query range lama jika ada.
      final q = Map<String, String>.from(url.queryParameters)..remove('range');
      return url.replace(queryParameters: q);
    }
    final q = Map<String, String>.from(url.queryParameters)
      ..['range'] = '$from-$to';
    return url.replace(queryParameters: q);
  }

  static Future<void> _viaExplodeStream(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? yt,
  }) async {
    final explode = yt ?? YoutubeExplode();
    final owned = yt == null;
    final sink = File(path).openWrite(mode: FileMode.writeOnly);
    var received = 0;
    final total = info.size.totalBytes;
    try {
      await for (final chunk in explode.videos.streamsClient.get(info).timeout(
        const Duration(seconds: 30),
        onTimeout: (s) {
          s.addError(TimeoutException('stall'));
          s.close();
        },
      )) {
        sink.add(chunk);
        received += chunk.length;
        onBytes(received, total <= 0 ? received : total);
      }
      await sink.flush();
    } finally {
      await sink.close();
      if (owned) explode.close();
    }
    if (received < 2048) throw Exception('File terlalu kecil');
  }
}
