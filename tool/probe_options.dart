import "package:youtube_explode_dart/youtube_explode_dart.dart";
void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.ios, YoutubeApiClient.androidSdkless]);
  final heights = <int>{
    ...m.muxed.map((s) => s.videoResolution.height),
    ...m.videoOnly.map((s) => s.videoResolution.height),
    ...m.hls.whereType<HlsVideoStreamInfo>().map((s) => s.videoResolution.height),
  }.where((h) => h > 0 && h <= 1080).toList()..sort((a,b)=>b.compareTo(a));
  print("option heights: $heights");
  final and720 = m.videoOnly.where((s)=>s.videoResolution.height==720 && (s.url.queryParameters["c"]??"")=="ANDROID").length;
  final iosHls720 = m.hls.whereType<HlsVideoStreamInfo>().where((s)=>s.videoResolution.height==720).length;
  print("ANDROID progressive 720 count=$and720 HLS720=$iosHls720");
  yt.close();
}
