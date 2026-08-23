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

    void emit(
      String phase,
      double progress, {
      int downloaded = 0,
      int total = 0,
      double speed = 0,
    }) {
      onProgress(
        DownloadProgress(
          phase: phase,
          progress: progress.clamp(0, 1),
          downloadedBytes: downloaded,
          totalBytes: total,
          speedBytesPerSecond: speed,
        ),
      );
    }

    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';
    final docs = await getApplicationDocumentsDirectory();
    final workDir = Directory(p.join(docs.path, 'clips', video.id.value));
    if (await workDir.exists()) await workDir.delete(recursive: true);
    await workDir.create(recursive: true);

    emit('Mengunduh audio slim...', 0.05);
    final audioPath = await YtDlpService.instance.downloadAudio(
      videoId: video.id.value,
      outputDir: p.join(workDir.path, 'audio'),
      videoDuration: video.duration,
      forTranscribe: true,
      onProgress: (p) => emit(
        p.phase,
        0.05 + 0.30 * p.progress01,
        downloaded: p.downloadedBytes,
        total: p.totalBytes,
        speed: p.speedBytesPerSecond,
      ),
    );

    emit(
      'Transkrip audio (Whisper)...',
      0.38,
      downloaded: await File(audioPath).length(),
      total: await File(audioPath).length(),
    );
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
        onProgress: (p) {
          emit(
            'Klip ${i + 1}/${hooks.length}: ${p.phase}',
            0.55 + 0.40 * ((i + p.progress01) / hooks.length),
            downloaded: p.downloadedBytes,
            total: p.totalBytes,
            speed: p.speedBytesPerSecond,
          );
        },
      );
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
