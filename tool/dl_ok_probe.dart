import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../lib/services/stream_downloader.dart';
import '../lib/services/youtube_service.dart';

Future<void> main() async {
  final yt = YoutubeService();
  try {
    final id = 'jNQXAC9IVRw';
    // mimic download service: video then fresh audio
    final m1 = await yt.getManifest(id);
    final v = yt.videoOnlyAt(m1, 360) ?? m1.videoOnly.first;
    final vp = 'tool/_v.bin';
    final sw = Stopwatch()..start();
    await StreamDownloader.download(yt.client, v, vp, onBytes: (r,t) {});
    print('video FULL ${File(vp).lengthSync()} / ${v.size.totalBytes} in ${sw.elapsedMilliseconds}ms');

    await Future.delayed(const Duration(milliseconds: 400));
    final m2 = await yt.getManifest(id);
    final a = yt.bestAudio(m2)!;
    final ap = 'tool/_a.bin';
    sw.reset(); sw.start();
    await StreamDownloader.download(yt.client, a, ap, onBytes: (r,t) {});
    print('audio FULL ${File(ap).lengthSync()} / ${a.size.totalBytes} in ${sw.elapsedMilliseconds}ms');
    File(vp).deleteSync(); File(ap).deleteSync();
    print('STRATEGY OK');
  } catch (e) {
    print('FAIL $e');
  } finally {
    yt.dispose();
  }
}
