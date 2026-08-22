import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main() async {
  final yt = YoutubeExplode();
  try {
    print('search...');
    final r = await yt.search.search('flutter tutorial');
    print('ok count=${r.length} first=${r.isEmpty ? "-" : r.first.title}');
  } catch (e) {
    print('SEARCH_ERR: $e');
  }
  try {
    print('video...');
    final v = await yt.videos.get('dQw4w9WgXcQ');
    print('ok title=${v.title}');
  } catch (e) {
    print('VIDEO_ERR: $e');
  }
  try {
    print('manifest...');
    final m = await yt.videos.streamsClient.getManifest(
      'dQw4w9WgXcQ',
      ytClients: [YoutubeApiClient.androidVr],
    );
    print('ok audio=${m.audioOnly.length} video=${m.videoOnly.length}');
  } catch (e) {
    print('MANIFEST_ERR: $e');
  }
  yt.close();
}
