import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  for (final clients in [
    [YoutubeApiClient.safari],
    [YoutubeApiClient.ios],
    [YoutubeApiClient.androidVr],
    [YoutubeApiClient.androidSdkless],
  ]) {
    final name = clients.first == YoutubeApiClient.safari
        ? 'safari'
        : clients.first == YoutubeApiClient.ios
            ? 'ios'
            : clients.first == YoutubeApiClient.androidVr
                ? 'vr'
                : 'sdkless';
    try {
      final m = await yt.videos.streamsClient.getManifest(
        'dQw4w9WgXcQ',
        ytClients: clients,
      );
      print('$name mux=${m.muxed.length} vo=${m.videoOnly.length} hls=${m.hls.length}');
      for (final h in m.hls) {
        final vh = h is VideoStreamInfo ? (h as VideoStreamInfo).videoResolution.height : 0;
        print('  hls thr=${h.isThrottled} h=$vh tag=${h.tag} cont=${h.container} size=${h.size.totalBytes}');
      }
      final hlsMux = m.hls.whereType<HlsMuxedStreamInfo>().toList()
        ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
      if (hlsMux.isNotEmpty) {
        final best = hlsMux.first;
        print('  bestHlsMux ${best.videoResolution.height}p thr=${best.isThrottled}');
        final sw = Stopwatch()..start();
        var n = 0;
        await for (final c in yt.videos.streamsClient.get(best)) {
          n += c.length;
          if (n > 3 * 1024 * 1024) break; // sample 3MB
        }
        print('  sample ${n}B in ${sw.elapsedMilliseconds}ms');
      }
    } catch (e) {
      print('$name FAIL $e');
    }
  }
  yt.close();
}
