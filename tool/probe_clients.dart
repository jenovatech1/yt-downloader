import "package:youtube_explode_dart/youtube_explode_dart.dart";

Future<void> dump(String label, List<YoutubeApiClient> clients) async {
  final yt = YoutubeExplode();
  try {
    final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: clients);
    final hlsV = m.hls.whereType<HlsVideoStreamInfo>().map((s) => s.videoResolution.height).toSet().toList()..sort();
    final vo = m.videoOnly.map((s) => "${s.videoResolution.height}/${s.url.queryParameters["c"]}").toSet().toList();
    final mux = m.muxed.map((s) => s.videoResolution.height).toSet().toList()..sort();
    print("$label | muxed=$mux hlsHeights=$hlsV videoOnlySample=${vo.take(8).toList()} hlsCount=${m.hls.length}");
  } catch (e) {
    print("$label FAIL $e");
  } finally {
    yt.close();
  }
}

void main() async {
  await dump("ios", [YoutubeApiClient.ios]);
  await dump("androidVr", [YoutubeApiClient.androidVr]);
  await dump("androidSdkless", [YoutubeApiClient.androidSdkless]);
  await dump("tv", [YoutubeApiClient.tv]);
  await dump("safari", [YoutubeApiClient.safari]);
  await dump("ios+sdkless", [YoutubeApiClient.ios, YoutubeApiClient.androidSdkless]);
  // Check media package version
  print("done");
}
