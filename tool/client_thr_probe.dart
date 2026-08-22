import "dart:io";
import "package:youtube_explode_dart/youtube_explode_dart.dart";

Future<void> tryClient(String name, List<YoutubeApiClient> clients) async {
  final yt = YoutubeExplode();
  try {
    final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: clients);
    final mux = m.muxed.toList()..sort((a,b)=>b.videoResolution.height.compareTo(a.videoResolution.height));
    final v720 = m.videoOnly.where((s)=>s.videoResolution.height==720).toList();
    final v1080 = m.videoOnly.where((s)=>s.videoResolution.height==1080).toList();
    final a = m.audioOnly.isEmpty ? null : m.audioOnly.first;
    print("$name: mux=${m.muxed.length} vo=${m.videoOnly.length} ao=${m.audioOnly.length}");
    if (mux.isNotEmpty) {
      final x = mux.first;
      print("  bestMux h=${x.videoResolution.height} thr=${x.isThrottled} cont=${x.container} tag=${x.tag}");
    }
    for (final s in [...v720.take(1), ...v1080.take(1)]) {
      print("  v${s.videoResolution.height} thr=${s.isThrottled} cont=${s.container} codec=${s.videoCodec} tag=${s.tag} size=${s.size.totalBytes}");
    }
    if (a != null) print("  audio thr=${a.isThrottled} cont=${a.container} tag=${a.tag}");
  } catch (e) {
    print("$name FAIL: $e");
  } finally {
    yt.close();
  }
}

void main() async {
  await tryClient("default", [YoutubeApiClient.androidSdkless]);
  await tryClient("androidVr", [YoutubeApiClient.androidVr]);
  await tryClient("ios", [YoutubeApiClient.ios]);
  await tryClient("tv", [YoutubeApiClient.tv]);
  await tryClient("safari", [YoutubeApiClient.safari]);
  await tryClient("vr+ios", [YoutubeApiClient.androidVr, YoutubeApiClient.ios]);
}
