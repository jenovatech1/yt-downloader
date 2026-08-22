import 'dart:io';
import '../lib/services/youtube_service.dart';
import '../lib/services/yt_stream_downloader.dart';

Future<void> main() async {
  final yt = YoutubeService();
  try {
    final m = await yt.getManifest('dQw4w9WgXcQ');
    final v720 = yt.videoOnlyAt(m, 720);
    final v1080 = yt.videoOnlyAt(m, 1080);
    print('720=${v720?.size.totalBytes} throttled=${v720?.isThrottled}');
    print('1080=${v1080?.size.totalBytes} throttled=${v1080?.isThrottled}');
    final stream = v720 ?? v1080 ?? m.videoOnly.first;
    print('dl tag=${stream.tag} size=${stream.size.totalBytes} throttled=${stream.isThrottled}');
    final path = 'tool/_par.bin';
    final sw = Stopwatch()..start();
    var last = 0;
    await YtStreamDownloader.download(stream, path, yt: yt.client, onBytes: (r,t){
      if (r - last > 2*1024*1024) { print('  ${(r/t*100).toStringAsFixed(0)}%'); last = r; }
    });
    print('OK ${File(path).lengthSync()}/${stream.size.totalBytes} in ${sw.elapsedMilliseconds}ms');
    File(path).deleteSync();

    final a = yt.bestAudio(m)!;
    print('audio size=${a.size.totalBytes} throttled=${a.isThrottled}');
    await YtStreamDownloader.download(a, path, yt: yt.client, onBytes: (r,t){});
    print('audio OK ${File(path).lengthSync()}');
    File(path).deleteSync();
  } catch (e, st) {
    print('FAIL $e\n$st');
  } finally {
    yt.dispose();
  }
}
