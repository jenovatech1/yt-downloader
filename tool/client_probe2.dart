import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> probe(String id) async {
  final yt = YoutubeExplode();
  try {
    final v = await yt.videos.get(id);
    print('meta OK: ${v.title}');
    final m = await yt.videos.streamsClient.getManifest(id, ytClients: [
      YoutubeApiClient.androidVr,
      YoutubeApiClient.android,
      YoutubeApiClient.tv,
    ]);
    print('manifest OK muxed=${m.muxed.length} v=${m.videoOnly.length} a=${m.audioOnly.length}');
  } catch (e) {
    print('FAIL $id: ${e.runtimeType} $e');
  } finally {
    yt.close();
  }
}

Future<void> main() async {
  await probe('dQw4w9WgXcQ');
  await probe('jNQXAC9IVRw');
  // try default getManifest without clients
  final yt = YoutubeExplode();
  try {
    final m = await yt.videos.streamsClient.getManifest('dQw4w9WgXcQ');
    print('default clients OK a=${m.audioOnly.length}');
  } catch (e) {
    print('default FAIL: $e');
  } finally {
    yt.close();
  }
}
