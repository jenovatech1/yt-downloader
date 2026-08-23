import "dart:io";
import "package:http/http.dart" as http;
import "package:youtube_explode_dart/youtube_explode_dart.dart";

Future<int> dl(String label, Uri url, int from, int to, {bool useParam=true}) async {
  final client = http.Client();
  try {
    late http.Request req;
    if (useParam) {
      final q = Map<String, String>.from(url.queryParameters);
      q.remove("range");
      q["range"] = "$from-$to";
      q["rn"] = "1";
      req = http.Request("GET", url.replace(queryParameters: q));
    } else {
      final q = Map<String, String>.from(url.queryParameters)..remove("range");
      req = http.Request("GET", url.replace(queryParameters: q));
      req.headers["Range"] = "bytes=$from-$to";
    }
    req.headers["User-Agent"] = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
    req.headers["Connection"] = "close";
    final sw = Stopwatch()..start();
    final res = await client.send(req).timeout(Duration(seconds: 30));
    var n = 0;
    await for (final c in res.stream) { n += c.length; }
    print("$label http=${res.statusCode} got=$n in ${sw.elapsedMilliseconds}ms");
    return n;
  } catch (e) {
    print("$label FAIL $e");
    return 0;
  } finally { client.close(); }
}

void main() async {
  final yt = YoutubeExplode();
  final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.androidVr]);
  final v = m.videoOnly.firstWhere((s) => s.videoResolution.height == 720 && s.container.name.contains("mp4"));
  print("url c=${v.url.queryParameters["c"]} thr=${v.isThrottled}");
  // download full file with sequential range PARAM chunks like NewPipe
  final total = v.size.totalBytes;
  final chunk = 10379935;
  final sink = File("tool/_np720.bin").openWrite();
  var got = 0;
  final sw = Stopwatch()..start();
  var rn = 0;
  while (got < total) {
    final from = got;
    final to = (from + chunk < total ? from + chunk : total) - 1;
    rn++;
    final client = http.Client();
    try {
      final q = Map<String, String>.from(v.url.queryParameters);
      q.remove("range");
      q["range"] = "$from-$to";
      q["rn"] = "$rn";
      final req = http.Request("GET", v.url.replace(queryParameters: q));
      req.headers["User-Agent"] = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
      req.headers["Connection"] = "close";
      final res = await client.send(req).timeout(Duration(seconds: 60));
      if (res.statusCode != 200 && res.statusCode != 206) throw Exception("http ${res.statusCode}");
      await for (final c in res.stream) {
        sink.add(c);
        got += c.length;
      }
      print("chunk $from-$to ok total=$got/${total} rn=$rn");
    } finally { client.close(); }
  }
  await sink.close();
  print("FULL OK $got in ${sw.elapsedMilliseconds}ms");
  yt.close();
}
