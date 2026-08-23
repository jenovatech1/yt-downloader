import "dart:io";
import "package:youtube_explode_dart/youtube_explode_dart.dart";

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.ios]);
  final vids = m.hls.whereType<HlsVideoStreamInfo>().where((s) => s.videoResolution.height == 720).toList();
  final auds = m.hls.whereType<HlsAudioStreamInfo>().toList()..sort((a,b)=>b.bitrate.compareTo(a.bitrate));
  final mux = m.hls.whereType<HlsMuxedStreamInfo>().toList();
  print("hlsVideo720=${vids.length} hlsAudio=${auds.length} hlsMux=${mux.length}");
  if (vids.isEmpty) { yt.close(); return; }
  final v = vids.first;
  print("dl hls 720 tag=${v.tag} size=${v.size.totalBytes} thr=${v.isThrottled}");
  final sw = Stopwatch()..start();
  var n = 0;
  final f = File("tool/_hls720.bin");
  final sink = f.openWrite();
  await for (final c in yt.videos.streamsClient.get(v)) {
    sink.add(c);
    n += c.length;
    if (n % (5*1024*1024) < c.length) print("  ${(100*n/v.size.totalBytes).toStringAsFixed(0)}%");
  }
  await sink.close();
  print("VIDEO OK $n in ${sw.elapsedMilliseconds}ms");
  if (auds.isNotEmpty) {
    final a = auds.first;
    sw.reset(); sw.start();
    n = 0;
    final sink2 = File("tool/_hlsa.bin").openWrite();
    await for (final c in yt.videos.streamsClient.get(a)) {
      sink2.add(c); n += c.length;
    }
    await sink2.close();
    print("AUDIO OK $n in ${sw.elapsedMilliseconds}ms thr=${a.isThrottled}");
  }
  yt.close();
}
