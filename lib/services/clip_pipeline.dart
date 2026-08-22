import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_muxer_2025/youtube_muxer_2025.dart' as muxer;

import '../models/download_option.dart';
import '../models/download_progress.dart';
import '../models/hook_clip.dart';
import 'api_keys_service.dart';
import 'clip_ai_service.dart';

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

/// Get Clip: audio+video via NewPipe muxer (bukan youtube_explode yang hang).
class ClipPipeline {
  ClipPipeline();

  final _ai = ClipAiService();
  final _downloader = muxer.YoutubeDownloader();

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
    }) {
      onProgress(
        DownloadProgress(
          phase: phase,
          progress: progress.clamp(0, 1),
          downloadedBytes: downloaded,
          totalBytes: total,
          speedBytesPerSecond: 0,
        ),
      );
    }

    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';
    final docs = await getApplicationDocumentsDirectory();
    final workDir = Directory(p.join(docs.path, 'clips', video.id.value));
    if (await workDir.exists()) {
      await workDir.delete(recursive: true);
    }
    await workDir.create(recursive: true);

    emit('Mengunduh audio (NewPipe)...', 0.08);
    String? audioPath;
    await for (final prog in _downloader.downloadAudio(youtubeUrl)) {
      emit(
        prog.status.isNotEmpty ? prog.status : 'Mengunduh audio...',
        0.08 + 0.22 * prog.progress.clamp(0, 1),
      );
      if (prog.outputPath != null && prog.outputPath!.isNotEmpty) {
        audioPath = prog.outputPath;
      }
    }
    if (audioPath == null || !File(audioPath).existsSync()) {
      throw Exception('Gagal mengunduh audio (NewPipe).');
    }

    emit('Kompres audio...', 0.32);
    final smallAudio = p.join(workDir.path, 'audio_small.m4a');
    await _ffmpeg(
      [
        '-y',
        '-i',
        audioPath,
        '-c:a',
        'aac',
        '-b:a',
        '64k',
        '-ac',
        '1',
        smallAudio,
      ],
      fallback: [
        '-y',
        '-i',
        audioPath,
        '-c:a',
        'aac',
        '-b:a',
        '64k',
        smallAudio,
      ],
    );
    final transcribeFile =
        await File(smallAudio).exists() ? File(smallAudio) : File(audioPath);

    emit('Transkrip audio (AI)...', 0.40);
    final transcript = await _ai.transcribe(
      audioFile: transcribeFile,
      groqKey: groq,
      geminiKey: gemini,
    );

    final duration = video.duration ?? Duration.zero;
    emit('Mencari hook (AI)...', 0.55);
    final hooks = await _ai.suggestHooks(
      transcript: transcript,
      videoDuration: duration.inSeconds > 0
          ? duration
          : const Duration(minutes: 10),
      groqKey: groq,
      geminiKey: gemini,
      youtubeUrl: youtubeUrl,
    );
    if (hooks.isEmpty) {
      throw Exception('AI tidak menemukan hook di video ini.');
    }

    emit('Mengunduh video sumber (NewPipe)...', 0.60);
    final qualities = await _downloader.getQualities(youtubeUrl);
    final videoQs = qualities.where((q) => q.fps > 0).toList();
    if (videoQs.isEmpty) throw Exception('Tidak ada stream video.');
    final selected = _pickQuality(videoQs, option.height);

    String? sourceVideo;
    await for (final prog in _downloader.downloadVideo(selected, youtubeUrl)) {
      emit(
        prog.status.isNotEmpty ? prog.status : 'Mengunduh video...',
        0.60 + 0.20 * prog.progress.clamp(0, 1),
      );
      if (prog.outputPath != null && prog.outputPath!.isNotEmpty) {
        sourceVideo = prog.outputPath;
      }
    }
    if (sourceVideo == null || !File(sourceVideo).existsSync()) {
      throw Exception('Gagal mengunduh video sumber.');
    }

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
      await _cutLocal(
        sourcePath: sourceVideo,
        startSec: hook.startSec,
        durationSec: hook.endSec - hook.startSec,
        outputPath: outPath,
      );
      clips.add(
        HookClip(
          index: i,
          startSec: hook.startSec,
          endSec: hook.endSec,
          filePath: outPath,
          title: hook.reason ?? 'Klip ${i + 1}',
          hookScore: hook.score,
        ),
      );
    }

    try {
      if (await File(smallAudio).exists()) await File(smallAudio).delete();
    } catch (_) {}

    emit('Klip siap', 1);
    onProgress(
      DownloadProgress(
        phase: 'Klip siap',
        progress: 1,
        downloadedBytes: 0,
        totalBytes: 0,
        speedBytesPerSecond: 0,
        isDone: true,
      ),
    );

    return ClipPipelineResult(
      clips: clips,
      youtubeUrl: youtubeUrl,
      sourceTitle: video.title,
    );
  }

  muxer.VideoQuality _pickQuality(List<muxer.VideoQuality> list, int height) {
    int heightOf(muxer.VideoQuality q) {
      final m = RegExp(r'(\d{3,4})').firstMatch(q.quality);
      return int.tryParse(m?.group(1) ?? '') ?? 0;
    }

    final exact = list.where((q) => heightOf(q) == height).toList();
    if (exact.isNotEmpty) {
      exact.sort((a, b) => b.bitrate.compareTo(a.bitrate));
      return exact.first;
    }
    final below =
        list.where((q) => heightOf(q) <= height && heightOf(q) > 0).toList()
          ..sort((a, b) => heightOf(b).compareTo(heightOf(a)));
    if (below.isNotEmpty) return below.first;
    final sorted = [...list]
      ..sort((a, b) => heightOf(b).compareTo(heightOf(a)));
    return sorted.first;
  }

  Future<void> _cutLocal({
    required String sourcePath,
    required double startSec,
    required double durationSec,
    required String outputPath,
  }) async {
    final ss = startSec.toStringAsFixed(3);
    final t = durationSec.toStringAsFixed(3);
    await _ffmpeg(
      [
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
        'copy',
        '-movflags',
        '+faststart',
        outputPath,
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
        'mpeg4',
        '-q:v',
        '5',
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-movflags',
        '+faststart',
        outputPath,
      ],
    );
    final out = File(outputPath);
    if (!await out.exists() || await out.length() < 1024) {
      throw Exception('Gagal memotong klip di detik $ss');
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
