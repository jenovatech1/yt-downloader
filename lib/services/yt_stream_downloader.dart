import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Best practice 23 Agu 2026 (youtube_explode docs + yt-dlp android_sdkless):
///
/// - Muxed max ~360p — jangan andalkan untuk HD.
/// - HD: **HLS iOS** (m3u8 segments) ATAU **android_sdkless** progressive
///   dengan HTTP `Range` header (bukan `range=` query — itu sering 403 di HP).
/// - Jangan rebuild query URL (bisa rusak sig/n).
class YtStreamDownloader {
  YtStreamDownloader._();

  static const chunkBytes = 10379935;
  static const chunkTimeout = Duration(seconds: 45);
  static const maxRetries = 5;
  static const hlsParallelSegments = 8;
  static const parallelRangeWorkers = 8;

  /// Unduh rentang waktu dari progressive stream (ANDROID Range header — sama full).
  static Future<StreamTimeRangeResult> downloadStreamTimeRange(
    StreamInfo stream,
    String path, {
    required double rangeStartSec,
    required double rangeEndSec,
    required double videoDurationSec,
    required void Function(int received, int total, double speedBytesPerSecond)
        onBytes,
    double padSec = 5.0,
  }) async {
    final fileBytes = stream.size.totalBytes;
    if (fileBytes <= 0 || videoDurationSec <= 0) {
      throw StateError('Ukuran/durasi stream tidak diketahui');
    }

    final tStart = (rangeStartSec - padSec).clamp(0.0, videoDurationSec);
    final tEnd =
        (rangeEndSec + padSec).clamp(tStart + 0.5, videoDurationSec);
    final byteStart =
        (tStart / videoDurationSec * fileBytes).floor().clamp(0, fileBytes - 1);
    var byteEnd =
        (tEnd / videoDurationSec * fileBytes).ceil().clamp(byteStart, fileBytes);
    if (byteEnd >= fileBytes) byteEnd = fileBytes - 1;

    final dest = File(path);
    if (await dest.exists()) await dest.delete();
    await dest.parent.create(recursive: true);

    final span = byteEnd - byteStart + 1;
    final meter = ByteSpeedMeter();
    final c = (stream.url.queryParameters['c'] ?? '').toUpperCase();

    void report(int got) => onBytes(got, span, meter.tick(got));

    if (c == 'ANDROID') {
      await _downloadAndroidByteRange(
        stream,
        dest,
        byteStart: byteStart,
        byteEnd: byteEnd,
        onBytes: report,
      );
    } else {
      await _downloadQueryByteRange(
        stream,
        dest,
        byteStart: byteStart,
        byteEnd: byteEnd,
        onBytes: report,
      );
    }

    return StreamTimeRangeResult(fileStartSec: tStart, bytesWritten: span);
  }

  static Future<void> _downloadAndroidByteRange(
    StreamInfo stream,
    File dest, {
    required int byteStart,
    required int byteEnd,
    required void Function(int got) onBytes,
  }) async {
    final span = byteEnd - byteStart + 1;
    final tasks = <({int fileOffset, int from, int to})>[];
    var pos = 0;
    while (pos < span) {
      final from = byteStart + pos;
      final to = (from + chunkBytes - 1).clamp(byteStart, byteEnd);
      tasks.add((fileOffset: pos, from: from, to: to));
      pos = to - byteStart + 1;
    }

    final buffers = List<List<int>?>.filled(tasks.length, null);
    var next = 0;
    var totalGot = 0;

    await Future.wait(
      List.generate(
        parallelRangeWorkers.clamp(1, tasks.length),
        (_) async {
          while (true) {
            final i = next++;
            if (i >= tasks.length) return;
            final t = tasks[i];
            buffers[i] = await _fetchAndroidRangeChunk(stream, t.from, t.to);
            var partial = 0;
            for (final b in buffers) {
              if (b != null) partial += b.length;
            }
            totalGot = partial;
            onBytes(totalGot);
          }
        },
      ),
    );

    final sink = dest.openWrite();
    try {
      for (var i = 0; i < buffers.length; i++) {
        final data = buffers[i];
        if (data == null || data.isEmpty) {
          throw StateError('Chunk kosong index $i');
        }
        sink.add(data);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (totalGot < span * 0.85) {
      throw StateError('Download potongan tidak lengkap: $totalGot / $span');
    }
    onBytes(totalGot);
  }

  static Future<List<int>> _fetchAndroidRangeChunk(
    StreamInfo stream,
    int from,
    int to,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
      final client = http.Client();
      try {
        final req = http.Request('GET', stream.url);
        req.headers.addAll({
          'Range': 'bytes=$from-$to',
          'user-agent':
              'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
          'cookie': 'CONSENT=YES+cb',
          'accept': '*/*',
          'accept-language': 'en-US,en;q=0.5',
        });
        final res = await client.send(req).timeout(chunkTimeout);
        if (res.statusCode != 200 && res.statusCode != 206) {
          throw HttpException('HTTP ${res.statusCode} Range $from-$to');
        }
        final bytes = <int>[];
        await for (final chunk in res.stream.timeout(chunkTimeout)) {
          if (chunk.isNotEmpty) bytes.addAll(chunk);
        }
        if (bytes.isEmpty) throw StateError('Chunk kosong');
        return bytes;
      } catch (e) {
        lastError = e;
      } finally {
        client.close();
      }
    }
    throw StateError(
      'Gagal unduh chunk $from-$to setelah ${maxRetries}x: $lastError',
    );
  }

  static Future<void> _downloadQueryByteRange(
    StreamInfo stream,
    File dest, {
    required int byteStart,
    required int byteEnd,
    required void Function(int got) onBytes,
  }) async {
    final span = byteEnd - byteStart + 1;
    final sink = dest.openWrite();
    var got = 0;
    var rn = 0;
    try {
      while (got < span) {
        final from = byteStart + got;
        final to = (from + chunkBytes - 1).clamp(byteStart, byteEnd);
        rn++;
        Object? lastError;
        var ok = false;
        for (var attempt = 0; attempt < maxRetries && !ok; attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
          }
          final client = http.Client();
          try {
            var s = stream.url.toString();
            s = s.replaceAll(RegExp(r'&range=[^&]*'), '');
            s = s.replaceAll(RegExp(r'&rn=[^&]*'), '');
            s = '$s&range=$from-$to&rn=$rn';
            final req = http.Request('GET', Uri.parse(s));
            req.headers.addAll({
              'user-agent': _ua(stream.url),
              'cookie': 'CONSENT=YES+cb',
              'accept': '*/*',
            });
            final res = await client.send(req).timeout(chunkTimeout);
            if (res.statusCode != 200 && res.statusCode != 206) {
              throw HttpException('HTTP ${res.statusCode}');
            }
            var chunkGot = 0;
            await for (final chunk in res.stream.timeout(chunkTimeout)) {
              if (chunk.isEmpty) continue;
              sink.add(chunk);
              got += chunk.length;
              chunkGot += chunk.length;
              onBytes(got);
            }
            if (chunkGot <= 0) throw StateError('Chunk kosong');
            ok = true;
          } catch (e) {
            lastError = e;
          } finally {
            client.close();
          }
        }
        if (!ok) throw StateError('Gagal chunk $from-$to: $lastError');
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onBytes(got);
  }

  /// Hasil unduh HLS untuk rentang waktu — dipakai trim akurat.
  static Future<HlsTimeRangeResult> downloadHlsTimeRange(
    StreamInfo stream,
    String path, {
    required double rangeStartSec,
    required double rangeEndSec,
    required void Function(int received, int total, double speedBytesPerSecond)
        onBytes,
    double padSec = 2.0,
  }) async {
    final dest = File(path);
    if (await dest.exists()) await dest.delete();
    await dest.parent.create(recursive: true);

    final client = http.Client();
    final headers = {
      'user-agent':
          'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
      'accept': '*/*',
      'cookie': 'CONSENT=YES+cb',
    };
    try {
      final resolved = await _resolveHlsMediaPlaylist(stream, client, headers);
      final timed = _parseTimedSegments(resolved.body, resolved.base);
      if (timed.isEmpty) throw StateError('HLS tanpa segment');

      final start = (rangeStartSec - padSec).clamp(0.0, double.infinity);
      final end = rangeEndSec + padSec;
      final picked = timed.where((s) {
        if (s.isInit) return true;
        return s.endSec > start && s.startSec < end;
      }).toList();
      if (picked.length <= 1 && timed.length > 1) {
        throw StateError('Rentang HLS tidak ketemu segment');
      }

      final firstMedia = picked.firstWhere((s) => !s.isInit, orElse: () => picked.first);
      final totalEst = stream.size.totalBytes > 0
          ? (stream.size.totalBytes *
                  ((end - start) /
                      timed
                          .where((s) => !s.isInit)
                          .fold<double>(0, (a, s) => a + s.durationSec)))
              .round()
              .clamp(256 * 1024, stream.size.totalBytes)
          : picked.length * 400 * 1024;

      var got = 0;
      final meter = ByteSpeedMeter();
      final sink = dest.openWrite();
      try {
        final init = picked.where((s) => s.isInit).map((s) => s.uri).toList();
        final mediaSegs =
            picked.where((s) => !s.isInit).map((s) => s.uri).toList();
        final ordered = [...init, ...mediaSegs];

        final buffers = List<List<int>?>.filled(ordered.length, null);
        var nextIdx = 0;
        await Future.wait(
          List.generate(
            hlsParallelSegments.clamp(1, ordered.length),
            (_) async {
              while (true) {
                final i = nextIdx++;
                if (i >= ordered.length) return;
                buffers[i] =
                    await _fetchHlsSegment(client, ordered[i], headers);
                var partial = 0;
                for (final b in buffers) {
                  if (b != null) partial += b.length;
                }
                onBytes(partial.clamp(0, totalEst), totalEst, meter.tick(partial));
              }
            },
          ),
        );
        for (final b in buffers) {
          if (b == null || b.isEmpty) {
            throw StateError('Segment HLS kosong');
          }
          sink.add(b);
          got += b.length;
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (got < 2048) throw StateError('Potongan HLS terlalu kecil ($got)');
      onBytes(got, got > totalEst ? got : totalEst, meter.tick(got));
      return HlsTimeRangeResult(
        firstSegmentStartSec: firstMedia.startSec,
        bytesWritten: got,
      );
    } finally {
      client.close();
    }
  }

  static Future<List<int>> _fetchHlsSegment(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    Object? last;
    for (var a = 0; a < maxRetries; a++) {
      if (a > 0) {
        await Future<void>.delayed(Duration(milliseconds: 300 * a));
      }
      try {
        final res =
            await client.get(uri, headers: headers).timeout(chunkTimeout);
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
          throw HttpException('Segment HTTP ${res.statusCode}');
        }
        return res.bodyBytes;
      } catch (e) {
        last = e;
      }
    }
    throw StateError('Segment gagal: $last');
  }

  static Future<({String body, Uri base})> _resolveHlsMediaPlaylist(
    StreamInfo stream,
    http.Client client,
    Map<String, String> headers,
  ) async {
    final playlistRes = await client
        .get(stream.url, headers: headers)
        .timeout(const Duration(seconds: 30));
    if (playlistRes.statusCode != 200) {
      throw HttpException('HLS playlist HTTP ${playlistRes.statusCode}');
    }
    var body = playlistRes.body;
    var base = stream.url;
    if (body.contains('#EXT-X-STREAM-INF')) {
      final media = _firstMedia(body, stream.url);
      if (media == null) throw StateError('HLS master tanpa media');
      final mediaRes = await client
          .get(media, headers: headers)
          .timeout(const Duration(seconds: 30));
      if (mediaRes.statusCode != 200) {
        throw HttpException('HLS media HTTP ${mediaRes.statusCode}');
      }
      body = mediaRes.body;
      base = media;
    }
    return (body: body, base: base);
  }

  static List<HlsTimedSegment> _parseTimedSegments(String playlist, Uri base) {
    final lines = playlist.split('\n');
    final out = <HlsTimedSegment>[];
    var t = 0.0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final m = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (m != null) {
          out.add(
            HlsTimedSegment(
              uri: base.resolve(m.group(1)!),
              startSec: 0,
              durationSec: 0,
              isInit: true,
            ),
          );
        }
        continue;
      }
      if (!line.startsWith('#EXTINF:')) continue;
      final dm = RegExp(r'#EXTINF:([\d.]+)').firstMatch(line);
      final dur = double.tryParse(dm?.group(1) ?? '') ?? 6.0;
      Uri? uri;
      for (var j = i + 1; j < lines.length; j++) {
        final n = lines[j].trim();
        if (n.isEmpty || n.startsWith('#')) continue;
        uri = base.resolve(n);
        break;
      }
      if (uri == null) continue;
      out.add(
        HlsTimedSegment(
          uri: uri,
          startSec: t,
          durationSec: dur,
        ),
      );
      t += dur;
    }
    return out;
  }

  static Future<void> download(
    StreamInfo stream,
    String path, {
    YoutubeExplode? yt,
    required void Function(int received, int total) onBytes,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    final dest = File(path);
    if (await dest.exists()) await dest.delete();
    await dest.parent.create(recursive: true);

    final container = stream.container.name.toLowerCase();
    final isHls = container.contains('m3u8') ||
        container.contains('hls') ||
        stream is HlsVideoStreamInfo ||
        stream is HlsAudioStreamInfo ||
        stream is HlsMuxedStreamInfo;

    if (isHls) {
      await _downloadHls(stream, dest, onBytes: onBytes);
      return;
    }

    final c = (stream.url.queryParameters['c'] ?? '').toUpperCase();
    if (c == 'ANDROID') {
      await _downloadAndroidRange(
        stream,
        dest,
        onBytes: onBytes,
        refreshStream: refreshStream,
      );
      return;
    }

    // ANDROID_VR / IOS progressive / lainnya: append &range= (library style)
    // atau library get bila yt tersedia.
    if (yt != null && (c.contains('IOS') || c.isEmpty)) {
      try {
        await _downloadViaLibrary(yt, stream, dest, onBytes: onBytes);
        return;
      } catch (_) {
        // fall through to range-param DIY
      }
    }

    await _downloadRangeQuery(
      stream,
      dest,
      onBytes: onBytes,
      refreshStream: refreshStream,
    );
  }

  static Future<void> _downloadViaLibrary(
    YoutubeExplode yt,
    StreamInfo stream,
    File dest, {
    required void Function(int received, int total) onBytes,
  }) async {
    final sink = dest.openWrite();
    final total = stream.size.totalBytes;
    var got = 0;
    try {
      await for (final chunk in yt.videos.streamsClient.get(stream).timeout(
        const Duration(seconds: 35),
        onTimeout: (s) {
          s.addError(TimeoutException('Macet 35s tanpa data'));
          s.close();
        },
      )) {
        if (chunk.isEmpty) continue;
        sink.add(chunk);
        got += chunk.length;
        onBytes(got, total <= 0 ? got : total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (got < 2048) throw StateError('File terlalu kecil ($got byte)');
  }

  /// android_sdkless / ANDROID: Range **header** only (youtube_explode rule).
  static Future<void> _downloadAndroidRange(
    StreamInfo stream,
    File dest, {
    required void Function(int received, int total) onBytes,
    FutureOr<StreamInfo> Function()? refreshStream,
  }) async {
    var info = stream;
    var total = info.size.totalBytes;
    if (total <= 0) {
      throw StateError('Ukuran stream tidak diketahui (itag=${info.tag}).');
    }

    final sink = dest.openWrite();
    var got = 0;
    try {
      while (got < total) {
        final from = got;
        final to = (from + chunkBytes < total ? from + chunkBytes : total) - 1;
        Object? lastError;
        var ok = false;
        for (var attempt = 0; attempt < maxRetries && !ok; attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
            if (refreshStream != null && attempt >= 1) {
              try {
                info = await refreshStream();
                final n = info.size.totalBytes;
                if (n > 0) total = n;
              } catch (_) {}
            }
          }
          final client = http.Client();
          try {
            final req = http.Request('GET', info.url);
            req.headers.addAll({
              'Range': 'bytes=$from-$to',
              'user-agent':
                  'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
              'cookie': 'CONSENT=YES+cb',
              'accept': '*/*',
              'accept-language': 'en-US,en;q=0.5',
            });
            final res = await client.send(req).timeout(chunkTimeout);
            if (res.statusCode != 200 && res.statusCode != 206) {
              throw HttpException('HTTP ${res.statusCode} Range $from-$to');
            }
            var chunkGot = 0;
            await for (final chunk in res.stream.timeout(chunkTimeout)) {
              if (chunk.isEmpty) continue;
              sink.add(chunk);
              got += chunk.length;
              chunkGot += chunk.length;
              onBytes(got, total);
            }
            if (chunkGot <= 0) throw StateError('Chunk kosong');
            ok = true;
          } catch (e) {
            lastError = e;
          } finally {
            client.close();
          }
        }
        if (!ok) {
          throw StateError(
            'Gagal unduh HD chunk $from-$to setelah ${maxRetries}x: $lastError',
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (got < total) {
      throw StateError('Download tidak lengkap: $got / $total');
    }
    onBytes(total, total);
  }

  static Future<void> _downloadRangeQuery(
    StreamInfo stream,
    File dest, {
    required void Function(int received, int total) onBytes,
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
        final to = (from + chunkBytes < total ? from + chunkBytes : total) - 1;
        rn++;
        Object? lastError;
        var ok = false;
        for (var attempt = 0; attempt < maxRetries && !ok; attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
            if (refreshStream != null && attempt >= 1) {
              try {
                info = await refreshStream();
                final n = info.size.totalBytes;
                if (n > 0) total = n;
              } catch (_) {}
            }
          }
          final client = http.Client();
          try {
            var s = info.url.toString();
            s = s.replaceAll(RegExp(r'&range=[^&]*'), '');
            s = s.replaceAll(RegExp(r'&rn=[^&]*'), '');
            s = '$s&range=$from-$to&rn=$rn';
            final req = http.Request('GET', Uri.parse(s));
            req.headers.addAll({
              'user-agent': _ua(info.url),
              'cookie': 'CONSENT=YES+cb',
              'accept': '*/*',
            });
            final res = await client.send(req).timeout(chunkTimeout);
            if (res.statusCode != 200 && res.statusCode != 206) {
              throw HttpException('HTTP ${res.statusCode}');
            }
            var chunkGot = 0;
            await for (final chunk in res.stream.timeout(chunkTimeout)) {
              if (chunk.isEmpty) continue;
              sink.add(chunk);
              got += chunk.length;
              chunkGot += chunk.length;
              onBytes(got, total);
            }
            if (chunkGot <= 0) throw StateError('Chunk kosong');
            ok = true;
          } catch (e) {
            lastError = e;
          } finally {
            client.close();
          }
        }
        if (!ok) {
          throw StateError('Gagal chunk $from-$to: $lastError');
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onBytes(total, total);
  }

  static Future<void> _downloadHls(
    StreamInfo stream,
    File dest, {
    required void Function(int received, int total) onBytes,
  }) async {
    final client = http.Client();
    final headers = {
      'user-agent':
          'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
      'accept': '*/*',
      'cookie': 'CONSENT=YES+cb',
    };
    try {
      final playlistRes = await client
          .get(stream.url, headers: headers)
          .timeout(const Duration(seconds: 30));
      if (playlistRes.statusCode != 200) {
        throw HttpException('HLS playlist HTTP ${playlistRes.statusCode}');
      }
      var body = playlistRes.body;
      var base = stream.url;
      if (body.contains('#EXT-X-STREAM-INF')) {
        final media = _firstMedia(body, stream.url);
        if (media == null) throw StateError('HLS master tanpa media');
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
          Object? last;
          var ok = false;
          for (var a = 0; a < maxRetries && !ok; a++) {
            if (a > 0) {
              await Future<void>.delayed(Duration(milliseconds: 300 * a));
            }
            try {
              final res = await client
                  .get(segments[i], headers: headers)
                  .timeout(chunkTimeout);
              if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
                throw HttpException('Segment HTTP ${res.statusCode}');
              }
              sink.add(res.bodyBytes);
              got += res.bodyBytes.length;
              ok = true;
            } catch (e) {
              last = e;
            }
          }
          if (!ok) throw StateError('Segment $i gagal: $last');
          final tip = estimated > 0 ? estimated : got;
          onBytes(got.clamp(0, tip), tip);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (got < 2048) throw StateError('HLS terlalu kecil ($got)');
      onBytes(got, got);
    } finally {
      client.close();
    }
  }

  static String _ua(Uri url) {
    final c = (url.queryParameters['c'] ?? '').toUpperCase();
    if (c.contains('ANDROID_VR')) {
      return 'com.google.android.apps.youtube.vr.oculus/1.56.21 '
          '(Linux; U; Android 12; eureka-user Build/SQ3A.220605.009.A1) gzip';
    }
    if (c.contains('IOS')) {
      return 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';
    }
    return 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
  }

  static Uri? _firstMedia(String master, Uri base) {
    final lines = master.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].trim().startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final n = lines[j].trim();
        if (n.isEmpty || n.startsWith('#')) continue;
        return base.resolve(n);
      }
    }
    return null;
  }

  static List<Uri> _parseSegments(String playlist, Uri base) {
    final out = <Uri>[];
    for (final raw in playlist.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final m = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (m != null) out.add(base.resolve(m.group(1)!));
        continue;
      }
      if (line.isEmpty || line.startsWith('#')) continue;
      out.add(base.resolve(line));
    }
    return out;
  }
}

class StreamTimeRangeResult {
  const StreamTimeRangeResult({
    required this.fileStartSec,
    required this.bytesWritten,
  });

  final double fileStartSec;
  final int bytesWritten;
}

class ByteSpeedMeter {
  int _lastBytes = 0;
  DateTime _lastAt = DateTime.now();
  double _lastSpeed = 0;

  double tick(int bytes) {
    final now = DateTime.now();
    final dt = now.difference(_lastAt).inMilliseconds / 1000.0;
    if (dt >= 0.3) {
      _lastSpeed = dt > 0 ? (bytes - _lastBytes) / dt : 0;
      _lastBytes = bytes;
      _lastAt = now;
    }
    return _lastSpeed;
  }
}

class HlsTimedSegment {
  const HlsTimedSegment({
    required this.uri,
    required this.startSec,
    required this.durationSec,
    this.isInit = false,
  });

  final Uri uri;
  final double startSec;
  final double durationSec;
  final bool isInit;

  double get endSec => startSec + durationSec;
}

class HlsTimeRangeResult {
  const HlsTimeRangeResult({
    required this.firstSegmentStartSec,
    required this.bytesWritten,
  });

  final double firstSegmentStartSec;
  final int bytesWritten;
}
