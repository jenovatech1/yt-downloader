import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../lib/services/chunked_stream_downloader.dart';
import '../lib/services/youtube_service.dart';

Future<void> main() async {
  final yt = YoutubeService();
  try {
    final id = 'jNQXAC9IVRw';
    final m = await yt.getManifest(id);
    final audio = yt.compactAudio(m)!;
    print('audio throttled=${audio.isThrottled} size=${audio.size.totalBytes} c=${audio.url.queryParameters['c']}');
    final path = 'tool/_chunk_audio.bin';
    final sw = Stopwatch()..start();
    await ChunkedStreamDownloader.download(audio, path, ytForRefresh: yt.client, onBytes: (r,t) {
      if (r == t || r % 50000 < 2000) stdout.write('.');
    });
    print('\nOK ${File(path).lengthSync()} in ${sw.elapsedMilliseconds}ms');
    File(path).deleteSync();

    final v = yt.videoOnlyAt(m, 360) ?? m.videoOnly.first;
    print('video throttled=${v.isThrottled} size=${v.size.totalBytes}');
    final vp = 'tool/_chunk_video.bin';
    sw.reset(); sw.start();
    await ChunkedStreamDownloader.download(v, vp, ytForRefresh: yt.client, onBytes: (r,t) {});
    print('video OK ${File(vp).lengthSync()} / ${v.size.totalBytes} in ${sw.elapsedMilliseconds}ms');
    File(vp).deleteSync();
  } catch (e, st) {
    print('FAIL $e\n$st');
  } finally {
    yt.dispose();
  }
}
