import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> tryClient(String name, List<YoutubeApiClient> clients) async {
  final yt = YoutubeExplode();
  try {
    final m = await yt.videos.streamsClient.getManifest('uEEaNN9DApc', ytClients: clients)
      .timeout(const Duration(seconds: 25));
    print('$name OK muxed=${m.muxed.length} v=${m.videoOnly.length} a=${m.audioOnly.length}');
  } catch (e) {
    print('$name FAIL: $e');
  } finally {
    yt.close();
  }
}

Future<void> main() async {
  await tryClient('androidVr', [YoutubeApiClient.androidVr]);
  await tryClient('android', [YoutubeApiClient.android]);
  await tryClient('tv', [YoutubeApiClient.tv]);
  await tryClient('mediaConnect', [YoutubeApiClient.mediaConnect]);
  await tryClient('safari', [YoutubeApiClient.safari]);
  await tryClient('mweb', [YoutubeApiClient.mweb]);
  await tryClient('ios', [YoutubeApiClient.ios]);
  await tryClient('vr+android+tv', [YoutubeApiClient.androidVr, YoutubeApiClient.android, YoutubeApiClient.tv]);
}
