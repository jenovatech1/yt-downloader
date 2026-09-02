import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  const id = 'dQw4w9WgXcQ';
  for (final entry in <String, List<YoutubeApiClient>?>{
    'default': null,
    'sdkless': [YoutubeApiClient.androidSdkless],
    'android': [YoutubeApiClient.android],
    'ios': [YoutubeApiClient.ios],
  }.entries) {
    try {
      final m = await yt.videos.streamsClient.getManifest(id, ytClients: entry.value);
      final v = m.videoOnly.where((s) => s.videoResolution.height == 720).firstOrNull;
      final a = m.audioOnly.firstOrNull;
      print('${entry.key} v720 frags=${v?.fragments.length ?? 0} thr=${v?.isThrottled}');
      print('${entry.key} audio frags=${a?.fragments.length ?? 0}');
    } catch (e) {
      print('${entry.key} FAIL: $e');
    }
  }
  yt.close();
}
