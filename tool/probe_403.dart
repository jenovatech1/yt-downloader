import "package:http/http.dart" as http;
import "package:youtube_explode_dart/youtube_explode_dart.dart";
import "package:youtube_explode_dart/src/extensions/helpers_extension.dart";

Future<void> tryOne(String label, Uri url, Map<String,String> headers, {required String mode}) async {
  final client = http.Client();
  try {
    late http.Request req;
    if (mode == "rebuild") {
      final q = Map<String, String>.from(url.queryParameters);
      q.remove("range");
      q["range"] = "0-65535";
      q["rn"] = "1";
      req = http.Request("GET", url.replace(queryParameters: q));
    } else if (mode == "append") {
      var s = url.toString();
      s = s.replaceAll(RegExp(r"&range=[^&]*"), "");
      s = s.replaceAll(RegExp(r"&rn=[^&]*"), "");
      s = "$s&range=0-65535&rn=1";
      req = http.Request("GET", Uri.parse(s));
    } else if (mode == "header") {
      req = http.Request("GET", url);
      req.headers["Range"] = "bytes=0-65535";
    } else if (mode == "setQP") {
      req = http.Request("GET", url.setQueryParam("range", "0-65535"));
    }
    req.headers.addAll(headers);
    final res = await client.send(req).timeout(Duration(seconds: 20));
    var n = 0;
    await for (final c in res.stream.take(3)) { n += c.length; }
    print("$label -> ${res.statusCode} ~$n");
  } catch (e) {
    print("$label FAIL $e");
  } finally { client.close(); }
}

void main() async {
  final yt = YoutubeExplode();
  final cases = <String, List<YoutubeApiClient>>{
    "androidVr": [YoutubeApiClient.androidVr],
    "androidSdkless": [YoutubeApiClient.androidSdkless],
  };
  for (final e in cases.entries) {
    try {
      final m = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: e.value);
      final v = m.videoOnly.where((s) => s.videoResolution.height == 720).firstOrNull ?? m.videoOnly.firstOrNull;
      if (v == null) { print("no video ${e.key}"); continue; }
      final c = v.url.queryParameters["c"] ?? "?";
      print("\n=== ${e.key} stream_c=$c thr=${v.isThrottled} ===");
      final uaVr = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
      final uaAnd = "com.google.android.youtube/20.10.38 (Linux; U; Android 12; US) gzip";
      final headers = {"User-Agent": c.contains("VR") ? uaVr : uaAnd, "Accept":"*/*", "Connection":"close"};
      await tryOne("append", v.url, headers, mode: "append");
      await tryOne("rebuild", v.url, headers, mode: "rebuild");
      await tryOne("setQP", v.url, headers, mode: "setQP");
      await tryOne("header", v.url, headers, mode: "header");
      await tryOne("rebuild+origin", v.url, {...headers, "Origin":"https://www.youtube.com", "Referer":"https://www.youtube.com/"}, mode: "rebuild");
      await tryOne("append+origin", v.url, {...headers, "Origin":"https://www.youtube.com", "Referer":"https://www.youtube.com/"}, mode: "append");
    } catch (err) {
      print("${e.key} FAIL $err");
    }
  }
  yt.close();
}
