import "dart:io";
import "package:http/http.dart" as http;
import "package:youtube_explode_dart/youtube_explode_dart.dart";

Future<List<Uri>> parseSegs(String body, Uri base) async {
  final out = <Uri>[];
  for (final raw in body.split("\n")) {
    final line = raw.trim();
    if (line.startsWith("#EXT-X-MAP:")) {
      final m = RegExp(r'URI="([^"]+)"').firstMatch(line);
      if (m != null) out.add(base.resolve(m.group(1)!));
      continue;
    }
    if (line.isEmpty || line.startsWith("#")) continue;
    out.add(base.resolve(line));
  }
  return out;
}

Future<void> dlHls(StreamInfo s, String path) async {
  final client = http.Client();
  final ua = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
  final headers = {"user-agent": ua, "cookie": "CONSENT=YES+cb", "accept": "*/*"};
  final pr = await client.get(s.url, headers: headers);
  print("playlist ${pr.statusCode} bytes=${pr.bodyBytes.length}");
  if (pr.statusCode != 200) throw Exception("playlist ${pr.statusCode}");
  var body = pr.body;
  var base = s.url;
  if (body.contains("#EXT-X-STREAM-INF")) {
    final lines = body.split("\n");
    for (var i=0;i<lines.length;i++) {
      if (lines[i].startsWith("#EXT-X-STREAM-INF")) {
        for (var j=i+1;j<lines.length;j++) {
          final n = lines[j].trim();
          if (n.isEmpty || n.startsWith("#")) continue;
          base = s.url.resolve(n);
          final mr = await client.get(base, headers: headers);
          body = mr.body;
          break;
        }
        break;
      }
    }
  }
  final segs = await parseSegs(body, base);
  print("segments=${segs.length}");
  final sink = File(path).openWrite();
  var got = 0;
  for (var i=0;i<segs.length;i++) {
    final r = await client.get(segs[i], headers: headers);
    if (r.statusCode != 200) throw Exception("seg $i ${r.statusCode}");
    sink.add(r.bodyBytes);
    got += r.bodyBytes.length;
    if (i % 10 == 0) print("seg $i/$got");
  }
  await sink.close();
  client.close();
  print("DONE $path size=$got");
}

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.ios]);
  final hv = m.hls.whereType<HlsVideoStreamInfo>().where((s) => s.videoResolution.height == 720).first;
  final ha = m.hls.whereType<HlsAudioStreamInfo>().toList()..sort((a,b)=>b.bitrate.compareTo(a.bitrate));
  Directory("tool").createSync(recursive: true);
  await dlHls(hv, "tool/hls_v.ts");
  await dlHls(ha.first, "tool/hls_a.ts");
  yt.close();
}
