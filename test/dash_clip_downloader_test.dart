import 'package:flutter_test/flutter_test.dart';
import 'package:yt_downloader/services/dash_clip_downloader.dart';

void main() {
  test('selects HLS audio when yt-dlp omits acodec', () {
    final info = <String, dynamic>{
      'formats': [
        {
          'format_id': '270',
          'protocol': 'm3u8_native',
          'height': 1080,
          'vcodec': 'avc1.640028',
          'acodec': 'none',
          'video_ext': 'mp4',
          'url': 'https://example.com/video.m3u8',
        },
        {
          'format_id': '234',
          'protocol': 'm3u8_native',
          'format': '234 - audio only (Default, high)',
          'vcodec': 'none',
          'audio_ext': 'mp4',
          'tbr': 130,
          'url': 'https://example.com/audio.m3u8',
        },
      ],
    };

    final streams = DashClipDownloader.instance.pickStreams(info);

    expect(streams.video?['format_id'], '270');
    expect(streams.audio?['format_id'], '234');
    expect(DashClipDownloader.instance.hasSegmentedStreams(info), isTrue);
  });

  test('prefers original HLS audio over higher bitrate auto dub', () {
    final info = <String, dynamic>{
      'requested_formats': [
        {
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'language': 'id-ID',
          'format_note': 'Indonesian (original)',
          'protocol': 'https',
        },
      ],
      'formats': [
        {
          'format_id': '270',
          'protocol': 'm3u8_native',
          'height': 1080,
          'vcodec': 'avc1.640028',
          'acodec': 'none',
          'video_ext': 'mp4',
          'url': 'https://example.com/video.m3u8',
        },
        {
          'format_id': '234-en',
          'protocol': 'm3u8_native',
          'format': 'English, audio only, high',
          'format_note': 'English auto-dub',
          'language': 'en',
          'vcodec': 'none',
          'audio_ext': 'mp4',
          'tbr': 160,
          'url': 'https://example.com/english.m3u8',
        },
        {
          'format_id': '234-id',
          'protocol': 'm3u8_native',
          'format': 'Indonesian, audio only',
          'format_note': 'Indonesian (original)',
          'language': 'id',
          'vcodec': 'none',
          'audio_ext': 'mp4',
          'tbr': 128,
          'url': 'https://example.com/indonesian.m3u8',
        },
      ],
    };

    final streams = DashClipDownloader.instance.pickStreams(info);

    expect(streams.audio?['format_id'], '234-id');
  });
}
