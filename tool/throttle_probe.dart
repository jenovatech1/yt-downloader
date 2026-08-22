import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> show(String name, List<YoutubeApiClient> clients) async {
  final yt = YoutubeExplode();
  try {
    final m = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw', ytClients: clients);
    final a = m.audioOnly.isEmpty ? null : m.audioOnly.first;
    final v = m.videoOnly.isEmpty ? null : m.videoOnly.first;
    final x = m.muxed.isEmpty ? null : m.muxed.first;
    void p(String label, StreamInfo? s) {
      if (s == null) { print('$name $label: none'); return; }
      final c = s.url.queryParameters['c'];
      print('$name $label: tag=${s.tag} throttled=${s.isThrottled} c=$c size=${s.size.totalBytes}');
      print('  url host=${s.url.host} hasRangeQ=${s.url.queryParameters.containsKey('range')}');
    }
    p('audio', a); p('video', v); p('muxed', x);
  } catch (e) {
    print('$name FAIL ${e.toString().split('\n').first}');
  } finally { yt.close(); }
}

Future<void> main() async {
  await show('sdkless', [YoutubeApiClient.androidSdkless]);
  await show('ios', [YoutubeApiClient.ios]);
  await show('android', [YoutubeApiClient.android]);
  await show('default', [YoutubeApiClient.androidSdkless]);
}
