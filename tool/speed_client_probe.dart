import "dart:io";
import "package:http/http.dart" as http;
import "package:youtube_explode_dart/youtube_explode_dart.dart";

Future<void> speedTest(String label, StreamInfo s) async {
  final url = s.url;
  print("$label tag=${s.tag} thr=${s.isThrottled} ratebypass=${url.queryParameters['ratebypass']} c=${url.queryParameters['c']} n=${url.queryParameters['n']?.substring(0,8)}...");
  final from = 0;
  final to = 2*1024*1024 - 1;
  final sw = Stopwatch()..start();
  late http.Request req;
  if (url.queryParameters['c'] == 'ANDROID') {
    req = http.Request('GET', url);
    req.headers['Range'] = 'bytes=$from-$to';
  } else {
    req = http.Request('GET', url.replace(queryParameters: {...url.queryParameters, 'range': '$from-$to'}));
  }
  req.headers['User-Agent'] = 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
  final client = http.Client();
  try {
    final res = await client.send(req).timeout(Duration(seconds: 60));
    var n = 0;
    await for (final c in res.stream) {
      n += c.length;
    }
    final sec = sw.elapsedMilliseconds / 1000.0;
    final kbps = n / 1024 / sec;
    print("  http=${res.statusCode} got=$n in ${sw.elapsedMilliseconds}ms => ${kbps.toStringAsFixed(0)} KB/s");
  } catch (e) {
    print("  FAIL $e");
  } finally {
    client.close();
  }
}

void main() async {
  for (final clients in [
    [YoutubeApiClient.androidSdkless],
    [YoutubeApiClient.androidVr],
    [YoutubeApiClient.ios],
  ]) {
    final yt = YoutubeExplode();
    try {
      final name = clients.first == YoutubeApiClient.androidVr ? 'VR' : clients.first == YoutubeApiClient.ios ? 'IOS' : 'SDKLESS';
      final m = await yt.videos.streamsClient.getManifest('dQw4w9WgXcQ', ytClients: clients);
      final v = m.videoOnly.firstWhere((s) => s.videoResolution.height == 720 && s.container.name.contains('mp4'));
      await speedTest(name, v);
    } catch (e) {
      print('manifest fail $e');
    }
    yt.close();
  }
}
