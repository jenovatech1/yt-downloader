import "package:youtube_explode_dart/youtube_explode_dart.dart";
void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.androidSdkless]);
  for (final h in [1080,720,480]) {
    final v = m.videoOnly.where((s)=>s.videoResolution.height==h && s.container.name.contains("mp4")).toList();
    print("$h -> ${v.length} streams c=${v.isEmpty?"?":v.first.url.queryParameters["c"]}");
  }
  yt.close();
}
