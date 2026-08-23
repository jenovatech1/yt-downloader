import 'dart:async';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'yt_stream_downloader.dart';

/// Wrapper — unduh via NewPipe-style [YtStreamDownloader], bukan streamsClient.get.
class StreamDownloader {
  static Future<void> download(
    YoutubeExplode yt,
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    Duration stallTimeout = const Duration(seconds: 25),
  }) {
    return YtStreamDownloader.download(
      info,
      path,
      yt: yt,
      onBytes: onBytes,
    ).timeout(
      stallTimeout * 20,
      onTimeout: () => throw TimeoutException(
        'Download macet terlalu lama. Coba lagi.',
      ),
    );
  }
}
