import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> tryOne(String name, List<YoutubeApiClient>? clients) async {
  final yt = YoutubeExplode();
  try {
    final m = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw', ytClients: clients)
      .timeout(const Duration(seconds: 30));
    print('$name OK muxed=${m.muxed.length} v=${m.videoOnly.length} a=${m.audioOnly.length}');
  } catch (e) {
    print('$name FAIL: ${e.toString().split("\n").first}');
  } finally {
    yt.close();
  }
}

Future<void> main() async {
  await tryOne('default(null)', null);
  await tryOne('androidSdkless', [YoutubeApiClient.androidSdkless]);
  await tryOne('androidVr', [YoutubeApiClient.androidVr]);
  await tryOne('android', [YoutubeApiClient.android]);
  await tryOne('ios', [YoutubeApiClient.ios]);
  await tryOne('tv', [YoutubeApiClient.tv]);
  await tryOne('safari', [YoutubeApiClient.safari]);
}
