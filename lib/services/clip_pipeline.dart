import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';
import '../models/download_progress.dart';
import '../models/hook_clip.dart';
import 'api_keys_service.dart';
import 'clip_ai_service.dart';
import 'yt_dlp_service.dart';

class ClipPipelineResult {
  const ClipPipelineResult({
    required this.clips,
    required this.youtubeUrl,
    required this.sourceTitle,
  });

  final List<HookClip> clips;
  final String youtubeUrl;
  final String sourceTitle;
}

class ClipPipeline {
  ClipPipeline();

  final _ai = ClipAiService();

  Future<ClipPipelineResult> run({
    required Video video,
    required DownloadOption option,
    required void Function(DownloadProgress progress) onProgress,
  }) async {
    final groq = await ApiKeysService.instance.groqKey();
    final gemini = await ApiKeysService.instance.geminiKey();
    if (groq.isEmpty && gemini.isEmpty) {
      throw Exception('Isi API key Groq atau Gemini di Pengaturan dulu.');
    }

    void emit(String phase, double progress) {
      onProgress(
        DownloadProgress(
          phase: phase,
          progress: progress.clamp(0, 1),
          downloadedBytes: 0,
          totalBytes: 0,
          speedBytesPerSecond: 0,
        ),
      );
    }

    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';
    final docs = await getApplicationDocumentsDirectory();
    final workDir = Directory(p.join(docs.path, 'clips', video.id.value));
    if (await workDir.exists()) await workDir.delete(recursive: true);
    await workDir.create(recursive: true);

    emit('Mengunduh audio (yt-dlp)...', 0.08);
    final audioPath = await YtDlpService.instance.downloadAudio(
      videoId: video.id.value,
      outputDir: p.join(workDir.path, 'audio'),
      onProgress: (pct, phase) => emit(phase, 0.08 + 0.24 * pct),
    );

    emit('Transkrip audio (AI)...', 0.35);
    final transcript = await _ai.transcribe(
      audioFile: File(audioPath),
      groqKey: groq,
      geminiKey: gemini,
    );
    emit('Cari hook (AI)...', 0.48);
    final hooks = await _ai.suggestHooks(
      transcript: transcript,
      videoDuration: video.duration ?? const Duration(minutes: 10),
      groqKey: groq,
      geminiKey: gemini,
      youtubeUrl: youtubeUrl,
    );
    if (hooks.isEmpty) {
      throw Exception('AI tidak menemukan hook. Coba video lain.');
    }

    final clips = <HookClip>[];
    for (var i = 0; i < hooks.length; i++) {
      final hook = hooks[i];
      emit(
        'Mengunduh klip ${i + 1}/${hooks.length}...',
        0.55 + 0.40 * (i / hooks.length),
      );
      final clipDir = p.join(workDir.path, 'clip_$i');
      final outPath = await YtDlpService.instance.downloadVideo(
        videoId: video.id.value,
        height: option.height.clamp(360, 1080),
        outputDir: clipDir,
        sectionStart: hook.startSec,
        sectionEnd: hook.endSec,
        onProgress: (pct, phase) {
          emit(
            'Klip ${i + 1}/${hooks.length}: $phase',
            0.55 + 0.40 * ((i + pct) / hooks.length),
          );
        },
      );
      // Pindah ke path stabil.
      final stable = p.join(
        workDir.path,
        'clip_${i.toString().padLeft(2, '0')}.mp4',
      );
      if (outPath != stable) {
        await File(outPath).copy(stable);
      }
      clips.add(
        HookClip(
          index: i,
          startSec: hook.startSec,
          endSec: hook.endSec,
          filePath: stable,
          title: hook.reason,
          hookScore: hook.score,
        ),
      );
    }

    emit('Selesai', 1);
    return ClipPipelineResult(
      clips: clips,
      youtubeUrl: youtubeUrl,
      sourceTitle: video.title,
    );
  }
}
