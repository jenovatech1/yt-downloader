import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'yt_stream_downloader.dart';

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
    );
  }
}
