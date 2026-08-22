import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Unduh stream YouTube dengan benar untuk stream throttle.
///
/// Strategi (mengikuti praktik yt-dlp / YouTube app):
/// - Stream **tidak** throttle (muxed): satu request penuh.
/// - Stream **throttle** (adaptive 720/1080/audio): potong ~2MB,
///   tiap potongan = HTTP client baru + `Connection: close`,
///   beberapa potongan paralel → bypass limit per-koneksi.
class YtStreamDownloader {
  /// YouTube app memakai ~2MB; >10MB sering di-throttle keras.
  static const chunkSize = 2 * 1024 * 1024;
  static const concurrency = 6;
  static const _ua =
      'com.google.android.youtube/19.29.1 (Linux; U; Android 14) gzip';
  static const _timeout = Duration(seconds: 60);

  static Future<void> download(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? yt,
  }) async {
    final total = info.size.totalBytes;
    if (total <= 0) {
      await _singleExplode(info, path, onBytes: onBytes, yt: yt);
      return;
    }

    // Muxed / non-throttle: cukup satu koneksi.
    if (!info.isThrottled) {
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
        await _parallelChunks(stream, path, onBytes: onBytes, yt: yt);
        return;
      } catch (e) {
        lastErr = e;
        try {
          if (await File(path).exists()) await File(path).delete();
        } catch (_) {}
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    throw Exception('Download gagal setelah retry: $lastErr');
  }

  static Future<StreamInfo?> _refresh(YoutubeExplode yt, StreamInfo info) async {
    try {
      final m = await yt.videos.streamsClient.getManifest(
        info.videoId.value,
        ytClients: [
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

  static Future<void> _parallelChunks(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? yt,
  }) async {
    final total = info.size.totalBytes;
    final file = File(path);
    if (await file.exists()) await file.delete();

    // Pre-allocate.
    final raf = await file.open(mode: FileMode.write);
    await raf.setPosition(total > 0 ? total - 1 : 0);
    if (total > 0) await raf.writeByte(0);
    await raf.close();

    final ranges = <(int, int)>[];
    for (var start = 0; start < total; start += chunkSize) {
      final end = math.min(start + chunkSize, total) - 1;
      ranges.add((start, end));
    }

    var url = info.url;
    var received = 0;
    // Progress counter aman untuk parallel di isolate yang sama.
    final progress = <int>[0];

    void addReceived(int n) {
      progress[0] += n;
      onBytes(progress[0].clamp(0, total), total);
    }

    // Proses batch paralel.
    for (var i = 0; i < ranges.length; i += concurrency) {
      // Segarkan URL tiap batch (n-param throttle).
      if (i > 0 && yt != null) {
        final fresh = await _refresh(yt, info);
        if (fresh != null) url = fresh.url;
      }

      final batch = ranges.skip(i).take(concurrency).toList();
      await Future.wait(
        batch.map((r) async {
          await _downloadOneRange(
            url: url,
            path: path,
            from: r.$1,
            to: r.$2,
            info: info,
            yt: yt,
            onPart: addReceived,
          );
        }),
      );
    }

    final len = await file.length();
    if (len < (total * 0.95).round()) {
      throw Exception('File terpotong ($len / $total)');
    }
    onBytes(total, total);
  }

  static Future<void> _downloadOneRange({
    required Uri url,
    required String path,
    required int from,
    required int to,
    required StreamInfo info,
    YoutubeExplode? yt,
    required void Function(int bytes) onPart,
  }) async {
    Object? lastErr;
    var currentUrl = url;

    for (var attempt = 1; attempt <= 4; attempt++) {
      // Client BARU tiap attempt — penting: jangan reuse koneksi yang sudah di-throttle.
      final client = http.Client();
      try {
        final isAndroid = currentUrl.queryParameters['c'] == 'ANDROID';
        final uri = isAndroid
            ? currentUrl.replace(
                queryParameters: Map<String, String>.from(
                  currentUrl.queryParameters,
                )..remove('range'),
              )
            : currentUrl.replace(
                queryParameters: Map<String, String>.from(
                  currentUrl.queryParameters,
                )..['range'] = '$from-$to',
              );

        final req = http.Request('GET', uri);
        req.headers[HttpHeaders.userAgentHeader] = _ua;
        req.headers[HttpHeaders.acceptHeader] = '*/*';
        req.headers[HttpHeaders.connectionHeader] = 'close';
        if (isAndroid) {
          req.headers[HttpHeaders.rangeHeader] = 'bytes=$from-$to';
        }

        final res = await client.send(req).timeout(_timeout);

        if (res.statusCode == 403) {
          try {
            await res.stream.drain<void>();
          } catch (_) {}
          if (yt != null) {
            final fresh = await _refresh(yt, info);
            if (fresh != null) {
              currentUrl = fresh.url;
              lastErr = Exception('403, refresh');
              continue;
            }
          }
          throw Exception('HTTP 403 range $from-$to');
        }
        if (res.statusCode != 200 && res.statusCode != 206) {
          try {
            await res.stream.drain<void>();
          } catch (_) {}
          throw Exception('HTTP ${res.statusCode} range $from-$to');
        }

        final bytes = <int>[];
        await for (final part in res.stream.timeout(
          _timeout,
          onTimeout: (s) {
            s.addError(TimeoutException('range stall'));
            s.close();
          },
        )) {
          bytes.addAll(part);
        }

        final expect = to - from + 1;
        if (bytes.length < math.min(expect, 1024) && bytes.length < expect) {
          throw Exception('Range pendek ${bytes.length}/$expect');
        }

        final raf = await File(path).open(mode: FileMode.append);
        try {
          await raf.setPosition(from);
          await raf.writeFrom(bytes);
        } finally {
          await raf.close();
        }
        onPart(bytes.length);
        return;
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      } finally {
        client.close();
      }
    }
    throw Exception('Range $from-$to gagal: $lastErr');
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
    } finally {
      client.close();
    }
  }

  static Future<void> _singleExplode(
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
      await for (final c in explode.videos.streamsClient.get(info).timeout(
        const Duration(seconds: 40),
        onTimeout: (s) {
          s.addError(TimeoutException('stall'));
          s.close();
        },
      )) {
        sink.add(c);
        received += c.length;
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
