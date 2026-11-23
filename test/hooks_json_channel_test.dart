import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

/// Mirrors the hooksJson shape built in player_screen `_openClipsInKlippod`.
Map<String, dynamic> buildClipHandoffHooks({
  required String title,
  required String youtubeUrl,
  required String channel,
}) {
  return {
    'schemaVersion': 3,
    'source': 'yt_downloader',
    'sourceTitle': title,
    'youtubeUrl': youtubeUrl,
    if (channel.trim().isNotEmpty) 'channelName': channel.trim(),
    if (channel.trim().isNotEmpty) 'sourceChannel': channel.trim(),
    'skipDetect': true,
    'skipWhisper': true,
    'clips': const [],
  };
}

void main() {
  test('includes channelName and sourceChannel when author present', () {
    final json = buildClipHandoffHooks(
      title: 'Video',
      youtubeUrl: 'https://www.youtube.com/watch?v=abc',
      channel: 'Jenovatech',
    );
    expect(json['channelName'], 'Jenovatech');
    expect(json['sourceChannel'], 'Jenovatech');
    expect(jsonEncode(json), contains('"sourceChannel":"Jenovatech"'));
  });

  test('omits channel keys when author blank', () {
    final json = buildClipHandoffHooks(
      title: 'Video',
      youtubeUrl: 'https://www.youtube.com/watch?v=abc',
      channel: '  ',
    );
    expect(json.containsKey('channelName'), isFalse);
    expect(json.containsKey('sourceChannel'), isFalse);
  });
}
