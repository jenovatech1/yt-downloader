import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main() async {
  final yt = YoutubeExplode();
  try {
    final id = 'dQw4w9WgXcQ';
    final m = await yt.videos.streamsClient.getManifest(id, ytClients: [
      YoutubeApiClient.androidVr,
      YoutubeApiClient.android,
      YoutubeApiClient.tv,
    ]);
    final audio = (m.audioOnly.toList()..sort((a,b)=>a.bitrate.compareTo(b.bitrate))).first;
    print('audio ${audio.bitrate} ${audio.container} size=${audio.size.totalBytes}');
    print('url ${audio.url}');

    // 1) explode stream
    final sw = Stopwatch()..start();
    var n = 0;
    try {
      await for (final c in yt.videos.streamsClient.get(audio).timeout(const Duration(seconds: 15))) {
        n += c.length;
        if (n > 100000) break;
      }
      print('explode ok bytes=$n in ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      print('explode FAIL after ${sw.elapsedMilliseconds}ms: $e');
    }

    // 2) plain http
    sw.reset(); sw.start();
    final client = HttpClient();
    try {
      final req = await client.getUrl(audio.url);
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final res = await req.close().timeout(const Duration(seconds: 15));
      print('http status=${res.statusCode} len=${res.contentLength}');
      n = 0;
      await for (final c in res) {
        n += c.length;
        if (n > 100000) break;
      }
      print('http ok bytes=$n in ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      print('http FAIL: $e');
    } finally {
      client.close();
    }
  } finally {
    yt.close();
  }
}
