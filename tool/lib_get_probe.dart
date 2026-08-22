import "dart:io";
import "package:youtube_explode_dart/youtube_explode_dart.dart";

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ");
  final v = m.videoOnly.firstWhere((s) => s.videoResolution.height == 720 && s.container.name.contains("mp4"));
  print("dl via library get() tag=${v.tag} size=${v.size.totalBytes} thr=${v.isThrottled}");
  final sw = Stopwatch()..start();
  var n = 0;
  final sink = File("tool/_lib720.bin").openWrite();
  await for (final c in yt.videos.streamsClient.get(v)) {
    sink.add(c);
    n += c.length;
    if (n % (2*1024*1024) < c.length) print("  ${(100*n/v.size.totalBytes).toStringAsFixed(0)}% $n");
  }
  await sink.close();
  print("OK $n in ${sw.elapsedMilliseconds}ms");
  yt.close();
}
