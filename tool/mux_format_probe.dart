import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:http/http.dart' as http;

void main() async {
  final yt = YoutubeExplode();
  final id = 'dQw4w9WgXcQ';
  final m = await yt.videos.streamsClient.getManifest(id, ytClients: [
    YoutubeApiClient.androidSdkless,
    YoutubeApiClient.ios,
  ]);
  print('--- muxed ---');
  for (final s in m.muxed) {
    print('h=\ cont=\ codec=\+\ thr=\ size=\ tag=\');
  }
  print('--- videoOnly (720/1080) ---');
  for (final s in m.videoOnly.where((s) => s.videoResolution.height >= 720)) {
    print('h=\ cont=\ codec=\ thr=\ size=\ tag=\');
  }
  print('--- audio ---');
  for (final s in m.audioOnly.take(5)) {
    print('cont=\ codec=\ thr=\ size=\ tag=\');
  }
  
  // Download small muxed and check magic bytes
  final mux = m.muxed.where((s) => s.videoResolution.height <= 360).toList()
    ..sort((a,b) => b.videoResolution.height.compareTo(a.videoResolution.height));
  if (mux.isEmpty) { print('no mux'); yt.close(); return; }
  final s = mux.first;
  print('dl mux tag=\ cont=\');
  final client = http.Client();
  final res = await client.get(s.url, headers: {
    'User-Agent': 'com.google.android.youtube/19.29.1 (Linux; U; Android 14) gzip',
    'Connection': 'close',
  });
  print('http=\ len=\');
  final b = res.bodyBytes.take(32).toList();
  print('magic=\');
  // ftyp?
  final asStr = String.fromCharCodes(res.bodyBytes.take(20).where((c) => c >= 32 && c < 127));
  print('ascii=\');
  client.close();
  yt.close();
}
