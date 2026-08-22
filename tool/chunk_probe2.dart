import 'dart:io';
import '../lib/services/chunked_stream_downloader.dart';
import '../lib/services/youtube_service.dart';

Future<void> main() async {
  final yt = YoutubeService();
  try {
    final m = await yt.getManifest('jNQXAC9IVRw');
    final stream = m.muxed.isNotEmpty
        ? m.muxed.first
        : m.videoOnly.first;
    print('using ${stream.runtimeType} throttled=${stream.isThrottled} size=${stream.size.totalBytes}');
    final p = 'tool/_c2.bin';
    final sw = Stopwatch()..start();
    await ChunkedStreamDownloader.download(stream, p, ytForRefresh: yt.client, onBytes: (r,t){
      if (r==t) print('done bytes');
    });
    print('OK ${File(p).lengthSync()}/${stream.size.totalBytes} ${sw.elapsedMilliseconds}ms');
    File(p).deleteSync();
  } catch (e, st) {
    print('FAIL $e');
  } finally {
    yt.dispose();
  }
}
