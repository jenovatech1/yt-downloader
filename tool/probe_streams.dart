import "package:youtube_explode_dart/youtube_explode_dart.dart";

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest(
    "dQw4w9WgXcQ",
    ytClients: [
      YoutubeApiClient.ios,
      YoutubeApiClient.androidVr,
      YoutubeApiClient.androidSdkless,
    ],
  );
  print("muxed=${m.muxed.length} videoOnly=${m.videoOnly.length} audioOnly=${m.audioOnly.length} hls=${m.hls.length}");
  for (final s in m.hls.take(8)) {
    print("HLS type=${s.runtimeType} container=${s.container.name} tag=${s.tag} size=${s.size.totalBytes} urlHost=${s.url.host}");
  }
  for (final s in m.videoOnly.where((x) => x.videoResolution.height == 720).take(3)) {
    print("VO720 c=${s.url.queryParameters["c"]} container=${s.container.name} thr=${s.isThrottled} itag=${s.tag}");
  }
  // Test: does streamsClient.get work for muxed 360?
  final mux = m.muxed.isEmpty ? null : (m.muxed.toList()..sort((a,b)=>a.videoResolution.height.compareTo(b.videoResolution.height))).first;
  if (mux != null) {
    print("testing library get muxed ${mux.qualityLabel}...");
    var n = 0;
    final sw = Stopwatch()..start();
    await for (final c in yt.videos.streamsClient.get(mux).take(20)) {
      n += c.length;
    }
    print("muxed library get: $n bytes in ${sw.elapsedMilliseconds}ms");
  }
  yt.close();
}
