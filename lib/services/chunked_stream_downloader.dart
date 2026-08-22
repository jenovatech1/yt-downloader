import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Unduh stream YouTube.
/// Utama: library `streamsClient.get()` (handle 403/throttle dengan benar).
/// Cadangan: Range chunk manual.
class ChunkedStreamDownloader {
  static const _chunkBytes = 10379935;
  static const _ua =
      'com.google.android.youtube/19.29.1 (Linux; U; Android 14) gzip';
  static const _stallTimeout = Duration(seconds: 40);

  static Future<void> download(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? ytForRefresh,
  }) async {
    Object? lastError;

    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        var current = info;
        if (attempt > 1 && ytForRefresh != null) {
          current = await _refreshStream(ytForRefresh, info) ?? info;
        }
        await _delete(path);
        await _viaExplodeStream(
          current,
          path,
          onBytes: onBytes,
          yt: ytForRefresh,
        );
        return;
      } catch (e) {
        lastError = e;
        await _delete(path);
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    // Cadangan Range — restart penuh max 2x kalau 403 di tengah.
    Object? rangeErr;
    var stream = info;
    for (var round = 1; round <= 2; round++) {
      try {
        if (ytForRefresh != null) {
          stream = await _refreshStream(ytForRefresh, stream) ?? stream;
        }
        await _delete(path);
        await _viaRangeChunks(
          stream,
          path,
          onBytes: onBytes,
          ytForRefresh: ytForRefresh,
        );
        return;
      } catch (e) {
        rangeErr = e;
        await _delete(path);
        await Future<void>.delayed(Duration(milliseconds: 600 * round));
      }
    }

    throw Exception('Download gagal.\n$lastError\n$rangeErr');
  }

  static Future<void> _delete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<StreamInfo?> _refreshStream(
    YoutubeExplode yt,
    StreamInfo info,
  ) async {
    try {
      final fresh = await yt.videos.streamsClient.getManifest(
        info.videoId.value,
        ytClients: [
          YoutubeApiClient.androidSdkless,
          YoutubeApiClient.ios,
        ],
      );
      for (final s in fresh.streams) {
        if (s.tag == info.tag) return s;
      }
    } catch (_) {}
    return null;
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
    final iterator = StreamIterator(explode.videos.streamsClient.get(info));
    try {
      while (true) {
        final has = await iterator.moveNext().timeout(
          _stallTimeout,
          onTimeout: () => throw TimeoutException(
            'Stream macet ${_stallTimeout.inSeconds}s @ $received byte',
          ),
        );
        if (!has) break;
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        sink.add(chunk);
        received += chunk.length;
        onBytes(received, total <= 0 ? received : total);
      }
      await sink.flush();
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {}
      await sink.close();
      if (owned) explode.close();
    }
    if (received < 2048) {
      throw Exception('File terlalu kecil ($received byte)');
    }
    if (total > 2048 && received < (total * 0.90).round()) {
      throw Exception('Terpotong ($received / $total)');
    }
  }

  static Future<void> _viaRangeChunks(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? ytForRefresh,
  }) async {
    final total = info.size.totalBytes;
    if (total <= 0) throw Exception('Ukuran stream tidak diketahui');

    final raf = await File(path).open(mode: FileMode.write);
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

        for (var attempt = 1; attempt <= 5; attempt++) {
          http.StreamedResponse? streamed;
          try {
            // Persis seperti youtube_explode: c == 'ANDROID' → header Range
            final isAndroid = url.queryParameters['c'] == 'ANDROID';
            final uri = isAndroid
                ? url.replace(
                    queryParameters: Map<String, String>.from(
                      url.queryParameters,
                    )..remove('range'),
                  )
                : url.replace(
                    queryParameters: Map<String, String>.from(
                      url.queryParameters,
                    )..['range'] = '$from-$to',
                  );

            final req = http.Request('GET', uri);
            req.headers[HttpHeaders.userAgentHeader] = _ua;
            req.headers[HttpHeaders.acceptHeader] = '*/*';
            if (isAndroid) {
              req.headers[HttpHeaders.rangeHeader] = 'bytes=$from-$to';
            }

            streamed = await client.send(req).timeout(_stallTimeout);

            if (streamed.statusCode == 403) {
              try {
                await streamed.stream.drain<void>();
              } catch (_) {}
              final fresh = ytForRefresh == null
                  ? null
                  : await _refreshStream(ytForRefresh, info);
              if (fresh != null) {
                url = fresh.url;
                lastErr = Exception('HTTP 403, URL di-refresh');
                await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
                continue;
              }
              throw Exception('HTTP 403 @ byte $from (URL refresh gagal)');
            }

            if (streamed.statusCode != 200 && streamed.statusCode != 206) {
              try {
                await streamed.stream.drain<void>();
              } catch (_) {}
              throw Exception('HTTP ${streamed.statusCode} @ $from-$to');
            }

            var chunkGot = 0;
            await for (final part in streamed.stream.timeout(
              _stallTimeout,
              onTimeout: (sink) {
                sink.addError(TimeoutException('chunk stall'));
                sink.close();
              },
            )) {
              if (part.isEmpty) continue;
              await raf.setPosition(from + chunkGot);
              await raf.writeFrom(part);
              chunkGot += part.length;
              received = from + chunkGot;
              onBytes(received, total);
            }

            if (chunkGot < 1024 && received < total) {
              throw Exception('Chunk terlalu kecil ($chunkGot)');
            }
            ok = true;
            break;
          } catch (e) {
            lastErr = e;
            try {
              await streamed?.stream.drain<void>();
            } catch (_) {}
            await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
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

    if (received < (total * 0.90).round()) {
      throw Exception('Download terpotong ($received / $total)');
    }
  }
}
