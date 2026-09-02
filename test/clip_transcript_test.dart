import 'package:flutter_test/flutter_test.dart';
import 'package:yt_downloader/models/clip_transcript.dart';
import 'package:yt_downloader/services/own_ai_clip.dart';

void main() {
  test('serializes Whisper word timestamps for Klippod', () {
    const transcript = ClipTranscript(
      stampedText: '[00:00:01.000-00:00:02.000] halo dunia',
      cues: [
        ClipTranscriptCue(
          startSec: 1,
          endSec: 2,
          text: 'halo dunia',
          wordTimings: [
            ClipTranscriptWord(word: 'halo', startSec: 1, endSec: 1.4),
            ClipTranscriptWord(word: 'dunia', startSec: 1.5, endSec: 2),
          ],
        ),
      ],
    );

    final words =
        ((transcript.toJson()['cues'] as List).first
                as Map<String, dynamic>)['wordTimings']
            as List;

    expect(words, hasLength(2));
    expect((words.last as Map<String, dynamic>)['word'], 'dunia');
    expect((words.last as Map<String, dynamic>)['startSec'], 1.5);
  });

  test('own AI prompt requires transcript language for clip titles', () {
    final prompt = buildOwnAiExportFile(
      transcript: '[00:00:01.000-00:00:02.000] Ini bahasa Indonesia.',
      videoTitle: 'English Video Title',
    );

    expect(prompt, contains('Ignore the video title'));
    expect(prompt, contains('Never translate Indonesian speech into English'));
    expect(
      prompt,
      contains('Write hook_text and keywords in that same language'),
    );
  });
}
