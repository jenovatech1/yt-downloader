import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../lib/services/youtube_service.dart';

Future<void> main() async {
  final yt = YoutubeService();
  try {
    final m = await yt.getManifest('dQw4w9WgXcQ');
    print('manifest ok audio=${m.audioOnly.length} video=${m.videoOnly.length} muxed=${m.muxed.length}');
    final audio = yt.bestAudio(m)!;
    print('best audio ${audio.bitrate} ${audio.container}');
    var n = 0;
    await for (final c in yt.openStream(audio)) {
      n += c.length;
      if (n > 200000) break;
    }
    print('stream bytes ok=$n');
    final search = await yt.search('flutter');
    print('search ok=${search.length}');
  } catch (e) {
    print('ERR $e');
  } finally {
    yt.dispose();
  }
}
