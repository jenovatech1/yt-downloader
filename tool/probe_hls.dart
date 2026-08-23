import "dart:io";
import "package:http/http.dart" as http;
import "package:youtube_explode_dart/youtube_explode_dart.dart";

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.ios]);
  final hv = m.hls.whereType<HlsVideoStreamInfo>().where((s) => s.videoResolution.height == 720).firstOrNull
      ?? m.hls.whereType<HlsVideoStreamInfo>().firstOrNull;
  final ha = m.hls.whereType<HlsAudioStreamInfo>().firstOrNull;
  print("hlsV=${hv?.videoResolution.height} hlsA=${ha != null} url=${hv?.url.host}");
  if (hv == null) { yt.close(); return; }
  final client = http.Client();
  final res = await client.get(hv.url, headers: {
    "user-agent": "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
    "cookie": "CONSENT=YES+cb",
  }).timeout(Duration(seconds: 20));
  print("playlist ${res.statusCode} len=${res.body.length} head=${res.body.split("\n").take(5).join(" | ")}");
  final lines = res.body.split("\n").where((l) => l.trim().isNotEmpty && !l.startsWith("#")).toList();
  print("segments=${lines.length}");
  if (lines.isNotEmpty) {
    final seg = hv.url.resolve(lines.first.trim());
    final sres = await client.get(seg, headers: {
      "user-agent": "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
      "cookie": "CONSENT=YES+cb",
    }).timeout(Duration(seconds: 20));
    print("seg0 ${sres.statusCode} bytes=${sres.bodyBytes.length}");
  }
  client.close();
  yt.close();
}
