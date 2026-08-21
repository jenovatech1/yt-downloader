import 'dart:async';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Unduh stream YouTube dengan stall-detect + resume Range + fallback explode.
class StreamDownloader {
  static const _ua =
      'com.google.android.youtube/19.09.37 (Linux; U; Android 14) gzip';
  static const _stallTimeout = Duration(seconds: 15);
  static const _connectTimeout = Duration(seconds: 20);

  /// Unduh [info] ke [path]. Progress via [onBytes].
  static Future<void> download(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? yt,
  }) async {
    Object? lastError;

    // 1) HTTP + Range resume (paling stabil di Android kalau URL valid).
    try {
      await _httpWithResume(
        info.url,
        path,
        expectedTotal: info.size.totalBytes,
        onBytes: onBytes,
      );
      return;
    } catch (e) {
      lastError = e;
      await _safeDelete(path);
    }

    // 2) youtube_explode stream (kadang perlu header internal library).
    if (yt != null) {
      try {
        await _explodeDownload(yt, info, path, onBytes: onBytes);
        return;
      } catch (e) {
        lastError = e;
        await _safeDelete(path);
      }
    }

    throw Exception('Gagal unduh stream: $lastError');
  }

  static Future<void> _httpWithResume(
    Uri url,
    String path, {
    required int expectedTotal,
    required void Function(int received, int total) onBytes,
  }) async {
    final file = File(path);
    var received = 0;
    if (await file.exists()) {
      received = await file.length();
    }

    var attempts = 0;
    while (attempts < 6) {
      attempts++;
      final client = HttpClient();
      client.connectionTimeout = _connectTimeout;
      client.userAgent = _ua;
      RandomAccessFile? raf;
      try {
        final req = await client.getUrl(url);
        req.headers.set(HttpHeaders.acceptHeader, '*/*');
        req.headers.set('Accept-Language', 'en-US,en;q=0.9');
        if (received > 0) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
        }
        final res = await req.close().timeout(_connectTimeout);
        if (res.statusCode == 416) {
          // Sudah lengkap menurut server.
          onBytes(received, expectedTotal > 0 ? expectedTotal : received);
          return;
        }
        if (res.statusCode != 200 && res.statusCode != 206) {
          throw Exception('HTTP ${res.statusCode}');
        }

        final total = res.statusCode == 206 && res.contentLength > 0
            ? received + res.contentLength
            : (res.contentLength > 0
                ? res.contentLength
                : (expectedTotal > 0 ? expectedTotal : 0));

        raf = await file.open(mode: received > 0 ? FileMode.append : FileMode.write);
        var gotChunk = false;
        await for (final chunk in res.timeout(
          _stallTimeout,
          onTimeout: (sink) {
            sink.addError(TimeoutException('stall'));
            sink.close();
          },
        )) {
          gotChunk = true;
          raf.writeFromSync(chunk);
          received += chunk.length;
          onBytes(received, total > 0 ? total : received);
        }

        if (!gotChunk && received == 0) {
          throw Exception('HTTP kosong');
        }

        // Selesai kalau mendekati total, atau server tutup tanpa total.
        if (total > 0 && received >= total - 256) {
          onBytes(received, total);
          return;
        }
        if (total <= 0 && gotChunk) {
          // Tanpa content-length: anggap selesai kalau stream close bersih.
          onBytes(received, received);
          return;
        }
        // Belum lengkap → retry Range.
        await Future<void>.delayed(Duration(milliseconds: 400 * attempts));
      } on TimeoutException {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempts));
        continue;
      } finally {
        try {
          await raf?.close();
        } catch (_) {}
        client.close(force: true);
      }
    }

    if (received < 2048) {
      throw Exception('HTTP gagal / terlalu kecil ($received byte)');
    }
    // Ada data tapi belum tentu lengkap — tetap terima kalau > 80% expected.
    if (expectedTotal > 0 && received < (expectedTotal * 0.85).round()) {
      throw Exception(
        'Download terpotong ($received / $expectedTotal byte)',
      );
    }
    onBytes(received, expectedTotal > 0 ? expectedTotal : received);
  }

  static Future<void> _explodeDownload(
    YoutubeExplode yt,
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
  }) async {
    final file = File(path);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    final total = info.size.totalBytes;
    var received = 0;
    final iterator = StreamIterator(yt.videos.streamsClient.get(info));
    try {
      final hasFirst = await iterator.moveNext().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException('explode no first byte'),
      );
      if (!hasFirst) throw Exception('Stream kosong');

      Future<void> writeCurrent() async {
        sink.add(iterator.current);
        received += iterator.current.length;
        onBytes(received, total <= 0 ? received : total);
      }

      await writeCurrent();
      while (true) {
        final more = await iterator.moveNext().timeout(
          _stallTimeout,
          onTimeout: () => throw TimeoutException('explode stall'),
        );
        if (!more) break;
        await writeCurrent();
      }
      await sink.flush();
      if (received < 2048) throw Exception('Explode terlalu kecil');
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {}
      await sink.close();
    }
  }

  static Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
