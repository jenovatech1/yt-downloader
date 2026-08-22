import '../lib/services/youtube_service.dart';

Future<void> main() async {
  final yt = YoutubeService();
  try {
    final r = await yt.search('podcast bisnis');
    print('count=${r.length}');
    if (r.isNotEmpty) {
      print('first=${r.first.title} | ${r.first.author} | ${r.first.id}');
    }
  } catch (e) {
    print('ERR $e');
  } finally {
    yt.dispose();
  }
}
