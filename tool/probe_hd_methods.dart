import "dart:io";
import "package:http/http.dart" as http;
import "package:youtube_explode_dart/youtube_explode_dart.dart";

Future<void> dlRangeHeader(StreamInfo v, String path) async {
  final total = v.size.totalBytes;
  final sink = File(path).openWrite();
  var got = 0;
  final chunk = 10379935;
  final sw = Stopwatch()..start();
  while (got < total) {
    final from = got;
    final to = (from + chunk < total ? from + chunk : total) - 1;
    final client = http.Client();
    try {
      final req = http.Request("GET", v.url);
      req.headers["Range"] = "bytes=$from-$to";
      req.headers["user-agent"] = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip";
      req.headers["cookie"] = "CONSENT=YES+cb";
      req.headers["accept"] = "*/*";
      final res = await client.send(req).timeout(Duration(seconds: 60));
      if (res.statusCode != 200 && res.statusCode != 206) throw Exception("HTTP ${res.statusCode}");
      await for (final c in res.stream) { sink.add(c); got += c.length; }
      print("chunk $from-$to ok got=$got");
    } finally { client.close(); }
  }
  await sink.close();
  print("DONE header $got in ${sw.elapsedMilliseconds}ms");
}

Future<void> dlLibrary(YoutubeExplode yt, StreamInfo v, String path) async {
  final sink = File(path).openWrite();
  var got = 0;
  final sw = Stopwatch()..start();
  await for (final c in yt.videos.streamsClient.get(v)) {
    sink.add(c); got += c.length;
  }
  await sink.close();
  print("DONE library $got in ${sw.elapsedMilliseconds}ms");
}

void main() async {
  final yt = YoutubeExplode();
  // ANDROID progressive 720
  final mAnd = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.androidSdkless]);
  final v = mAnd.videoOnly.firstWhere((s) => s.videoResolution.height == 720 && s.container.name.contains("mp4"));
  print("ANDROID 720 c=${v.url.queryParameters["c"]} thr=${v.isThrottled} size=${v.size.totalBytes}");
  await dlRangeHeader(v, "tool/and720_header.bin");
  // IOS HLS presence
  final mIos = await yt.videos.streamsClient.getManifest("dQw4w9WgXcQ", ytClients: [YoutubeApiClient.ios]);
  final ha = mIos.hls.whereType<HlsAudioStreamInfo>().length;
  final hv = mIos.hls.whereType<HlsVideoStreamInfo>().where((s)=>s.videoResolution.height==1080).length;
  print("IOS hlsAudio=$ha hls1080=$hv");
  // library get 720 android
  await dlLibrary(yt, v, "tool/and720_lib.bin");
  yt.close();
}
