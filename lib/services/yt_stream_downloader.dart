import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Unduh stream YouTube (tanpa yt-dlp native — hindari crash).
///
/// 1. Library `streamsClient.get()` (chunk ~10MB + refresh otomatis)
/// 2. Fallback HTTP sequential ~10MB
/// 3. Muxed: satu GET penuh
class YtStreamDownloader {
  static const chunkSize = 10379935;
  static const _ua =
      'com.google.android.youtube/19.29.1 (Linux; U; Android 14) gzip';
  static const _timeout = Duration(seconds: 90);

  static Future<void> download(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? yt,
  }) async {
    final total = info.size.totalBytes;

    if (!info.isThrottled && total > 0) {
      await _singleHttp(info.url, path, total, onBytes: onBytes);
      return;
    }

    Object? lastErr;
    var stream = info;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        if (attempt > 1 && yt != null) {
          stream = await _refresh(yt, info) ?? stream;
        }
        if (yt != null && attempt <= 2) {
          await _viaLibrary(yt, stream, path, onBytes: onBytes);
        } else {
          await _sequentialChunks(stream, path, onBytes: onBytes, yt: yt);
        }
        return;
      } catch (e) {
        lastErr = e;
        try {
          if (await File(path).exists()) await File(path).delete();
        } catch (_) {}
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
    throw Exception('Download gagal setelah retry: $lastErr');
  }

  static Future<void> _viaLibrary(
    YoutubeExplode yt,
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
  }) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
    final sink = file.openWrite(mode: FileMode.writeOnly);
    final total = info.size.totalBytes;
    var received = 0;
    try {
      await for (final chunk in yt.videos.streamsClient.get(info).timeout(
        const Duration(seconds: 45),
        onTimeout: (s) {
          s.addError(TimeoutException('stall 45s'));
          s.close();
        },
      )) {
        if (chunk.isEmpty) continue;
        sink.add(chunk);
        received += chunk.length;
        onBytes(received, total <= 0 ? received : total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received < 2048) throw Exception('File terlalu kecil ($received)');
    if (total > 0 && received < (total * 0.9).round()) {
      throw Exception('Download terpotong ($received / $total)');
    }
    onBytes(total > 0 ? total : received, total > 0 ? total : received);
  }

  static Future<StreamInfo?> _refresh(YoutubeExplode yt, StreamInfo info) async {
    try {
      final m = await yt.videos.streamsClient.getManifest(
        info.videoId.value,
        ytClients: [
          YoutubeApiClient.androidVr,
          YoutubeApiClient.androidSdkless,
          YoutubeApiClient.ios,
        ],
      );
      for (final s in m.streams) {
        if (s.tag == info.tag) return s;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _sequentialChunks(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? yt,
  }) async {
    final total = info.size.totalBytes;
    if (total <= 0) {
      final explode = yt ?? YoutubeExplode();
      final owned = yt == null;
      try {
        await _viaLibrary(explode, info, path, onBytes: onBytes);
      } finally {
        if (owned) explode.close();
      }
      return;
    }

    final file = File(path);
    if (await file.exists()) await file.delete();
    final sink = file.openWrite(mode: FileMode.writeOnly);
    var received = 0;
    var url = info.url;

    try {
      while (received < total) {
        final from = received;
        final to = math.min(from + chunkSize, total) - 1;
        Object? err;

        for (var attempt = 1; attempt <= 4; attempt++) {
          final client = http.Client();
          try {
            final c = url.queryParameters['c'] ?? '';
            final useHeader = c == 'ANDROID' || c.startsWith('ANDROID');
            final http.Request req;
            if (useHeader) {
              final clean = url.replace(
                queryParameters: Map<String, String>.from(url.queryParameters)
                  ..remove('range'),
              );
              req = http.Request('GET', clean);
              req.headers[HttpHeaders.rangeHeader] = 'bytes=$from-$to';
            } else {
              req = http.Request(
                'GET',
                url.replace(
                  queryParameters: Map<String, String>.from(
                    url.queryParameters,
                  )..['range'] = '$from-$to',
                ),
              );
            }
            req.headers[HttpHeaders.userAgentHeader] = _ua;
            req.headers[HttpHeaders.connectionHeader] = 'close';

            final res = await client.send(req).timeout(_timeout);
            if (res.statusCode == 403 && yt != null) {
              await res.stream.drain<void>();
              final fresh = await _refresh(yt, info);
              if (fresh != null) {
                url = fresh.url;
                err = Exception('403 refresh');
                continue;
              }
              throw Exception('HTTP 403 @$from');
            }
            if (res.statusCode != 200 && res.statusCode != 206) {
              await res.stream.drain<void>();
              throw Exception('HTTP ${res.statusCode} @$from');
            }

            await for (final part in res.stream.timeout(
              _timeout,
              onTimeout: (s) {
                s.addError(TimeoutException('chunk stall'));
                s.close();
              },
            )) {
              sink.add(part);
              received += part.length;
              onBytes(received, total);
            }
            err = null;
            break;
          } catch (e) {
            err = e;
            await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
          } finally {
            client.close();
          }
        }
        if (err != null) throw Exception('Chunk $from-$to: $err');
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (received < (total * 0.95).round()) {
      throw Exception('File terpotong ($received / $total)');
    }
    onBytes(total, total);
  }

  static Future<void> _singleHttp(
    Uri url,
    String path,
    int total, {
    required void Function(int received, int total) onBytes,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', url);
      req.headers[HttpHeaders.userAgentHeader] = _ua;
      req.headers[HttpHeaders.connectionHeader] = 'close';
      final res = await client.send(req).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final sink = File(path).openWrite(mode: FileMode.writeOnly);
      var received = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          onBytes(received, total <= 0 ? received : total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received < 2048) throw Exception('File terlalu kecil');
      if (total > 0 && received < (total * 0.95).round()) {
        throw Exception('File terpotong ($received / $total)');
      }
      onBytes(total > 0 ? total : received, total > 0 ? total : received);
    } finally {
      client.close();
    }
  }
}
