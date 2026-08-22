import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
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

    try {
      emit('Mengunduh audio (yt-dlp)...', 0.08);
      final audioPath = await YtDlpService.instance.downloadAudio(
        videoId: video.id.value,
        outputDir: p.join(workDir.path, 'audio'),
        onProgress: (pct, phase) => emit(phase, 0.08 + 0.22 * pct),
      );

      // Kompres bila perlu untuk upload AI.
      emit('Siapkan audio...', 0.32);
      final smallAudio = p.join(workDir.path, 'audio_small.m4a');
      await _ffmpeg(
        [
          '-y',
          '-i',
          audioPath,
          '-vn',
          '-c:a',
          'aac',
          '-b:a',
          '64k',
          '-ac',
          '1',
          '-ar',
          '16000',
          smallAudio,
        ],
        fallback: [
          '-y',
          '-i',
          audioPath,
          '-vn',
          '-c:a',
          'copy',
          smallAudio,
        ],
      );

      emit('Transkrip audio (AI)...', 0.40);
      final transcript = await _ai.transcribe(
        audioFile: File(smallAudio),
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

      emit('Mengunduh sumber video (yt-dlp)...', 0.58);
      final sourcePath = await YtDlpService.instance.downloadVideo(
        videoId: video.id.value,
        height: option.height.clamp(360, 1080),
        outputDir: p.join(workDir.path, 'source'),
        onProgress: (pct, phase) => emit(phase, 0.58 + 0.20 * pct),
      );

      final clips = <HookClip>[];
      for (var i = 0; i < hooks.length; i++) {
        final hook = hooks[i];
        emit(
          'Memotong klip ${i + 1}/${hooks.length}...',
          0.80 + 0.18 * (i / hooks.length),
        );
        final outPath = p.join(
          workDir.path,
          'clip_${i.toString().padLeft(2, '0')}.mp4',
        );
        final ss = hook.startSec.toStringAsFixed(3);
        final t = (hook.endSec - hook.startSec).toStringAsFixed(3);
        await _ffmpeg(
          [
            '-y',
            '-ss',
            ss,
            '-t',
            t,
            '-i',
            sourcePath,
            '-c',
            'copy',
            '-avoid_negative_ts',
            'make_zero',
            outPath,
          ],
          fallback: [
            '-y',
            '-ss',
            ss,
            '-t',
            t,
            '-i',
            sourcePath,
            '-c:v',
            'copy',
            '-c:a',
            'aac',
            '-b:a',
            '128k',
            outPath,
          ],
        );
        clips.add(
          HookClip(
            index: i,
            startSec: hook.startSec,
            endSec: hook.endSec,
            filePath: outPath,
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
    } catch (e) {
      emit('Gagal', 0);
      rethrow;
    }
  }

  Future<void> _ffmpeg(List<String> args, {List<String>? fallback}) async {
    var session = await FFmpegKit.executeWithArguments(args);
    var code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code)) return;
    if (fallback != null) {
      session = await FFmpegKit.executeWithArguments(fallback);
      code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code)) return;
    }
    final logs = await session.getAllLogsAsString();
    throw Exception(
      'FFmpeg gagal.\n${logs?.split('\n').take(6).join('\n') ?? ''}',
    );
  }
}
