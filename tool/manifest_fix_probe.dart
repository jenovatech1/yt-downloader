import '../lib/services/youtube_service.dart';

Future<void> main() async {
  final yt = YoutubeService();
  try {
    for (final id in ['jNQXAC9IVRw', 'dQw4w9WgXcQ']) {
      final m = await yt.getManifest(id);
      final opts = await yt.getDownloadOptions(id);
      print('$id OK streams a=${m.audioOnly.length} v=${m.videoOnly.length} mux=${m.muxed.length} options=${opts.length}');
    }
  } catch (e) {
    print('FAIL $e');
  } finally {
    yt.dispose();
  }
}
