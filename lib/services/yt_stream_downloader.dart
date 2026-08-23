import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Downloader berdasarkan riset Seal / NewPipe / yt-dlp (Agu 2026):
///
/// - Progressive adaptive (`android_vr` videoplayback + range) sering **HTTP 403**
///   di CDN HP — masalah industri (yt-dlp#17456, Seal#2414). Jangan dipakai.
/// - Seal = yt-dlp native (crash di device ini sebelumnya).
/// - NewPipe download = progressive HTTP saja; player pakai YoutubeHttpDataSource.
/// - Yang masih aman untuk HD di Flutter tanpa yt-dlp: **HLS iOS** (m3u8 segments).
/// - ≤360p: muxed via [StreamClient.get] (library).
class YtStreamDownloader {
  YtStreamDownloader._();

  static const segmentTimeout = Duration(seconds: 40);
  static const maxRetries = 4;

  static Future<void> download(
    StreamInfo stream,
    String path, {
    YoutubeExplode? yt,
    required void Function(int received, int total) onBytes,
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

    final client = yt;
    if (client == null) {
      throw StateError('YoutubeExplode required for progressive/muxed download');
    }
    await _downloadViaLibrary(client, stream, dest, onBytes: onBytes);
  }

  /// Library path — hanya untuk muxed kecil; ada stall timeout.
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
        const Duration(seconds: 30),
        onTimeout: (s) {
          s.addError(
            TimeoutException('Download macet 30s tanpa data'),
          );
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
    if (got < 2048) {
      throw StateError('File terlalu kecil ($got byte)');
    }
  }

  static Future<void> _downloadHls(
    StreamInfo stream,
    File dest, {
    required void Function(int received, int total) onBytes,
  }) async {
    final client = http.Client();
    final headers = _iosHeaders();
    try {
      final playlistRes = await client
          .get(stream.url, headers: headers)
          .timeout(const Duration(seconds: 30));
      if (playlistRes.statusCode != 200) {
        throw HttpException(
          'HLS playlist HTTP ${playlistRes.statusCode}',
        );
      }

      var body = playlistRes.body;
      var base = stream.url;
      if (body.contains('#EXT-X-STREAM-INF')) {
        final media = _firstMediaPlaylistUrl(body, stream.url);
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
      if (segments.isEmpty) {
        throw StateError('HLS playlist kosong / tidak dikenal');
      }

      final sink = dest.openWrite();
      var got = 0;
      final estimated = stream.size.totalBytes;
      try {
        for (var i = 0; i < segments.length; i++) {
          final bytes = await _getSegment(client, segments[i], headers);
          sink.add(bytes);
          got += bytes.length;
          final totalHint = estimated > 0 ? estimated : got;
          onBytes(got.clamp(0, totalHint), totalHint);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (got < 2048) {
        throw StateError('HLS hasil terlalu kecil ($got byte)');
      }
      onBytes(got, got);
    } finally {
      client.close();
    }
  }

  static Future<List<int>> _getSegment(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    Object? last;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
      try {
        final res =
            await client.get(uri, headers: headers).timeout(segmentTimeout);
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
          throw HttpException('Segment HTTP ${res.statusCode}');
        }
        return res.bodyBytes;
      } catch (e) {
        last = e;
      }
    }
    throw StateError('Segment gagal setelah ${maxRetries}x: $last');
  }

  static Map<String, String> _iosHeaders() => {
        'user-agent':
            'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
        'accept': '*/*',
        'accept-language': 'en-US,en;q=0.9',
        'cookie': 'CONSENT=YES+cb',
      };

  static Uri? _firstMediaPlaylistUrl(String master, Uri base) {
    final lines = master.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].trim().startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j].trim();
        if (next.isEmpty || next.startsWith('#')) continue;
        return base.resolve(next);
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
