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
import 'chunked_stream_downloader.dart';
import 'clip_ai_service.dart';
import 'youtube_service.dart';

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

    final yt = YoutubeService();
    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';
    try {
      final docs = await getApplicationDocumentsDirectory();
      final workDir = Directory(p.join(docs.path, 'clips', video.id.value));
      if (await workDir.exists()) await workDir.delete(recursive: true);
      await workDir.create(recursive: true);

      emit('Mengunduh audio...', 0.08);
      String? rawAudio;
      Object? lastErr;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final manifest = await yt.getManifest(video.id.value);
          final audio = yt.compactAudio(manifest) ?? yt.bestAudio(manifest);
          if (audio == null) throw Exception('Audio tidak tersedia');
          final path = p.join(
            workDir.path,
            'audio_${attempt}.${audio.container.name}',
          );
          await ChunkedStreamDownloader.download(
            audio,
            path,
            ytForRefresh: yt.client,
            onBytes: (r, t) {
              final f = t <= 0 ? 0.0 : r / t;
              emit('Mengunduh audio...', 0.08 + 0.22 * f);
            },
          );
          rawAudio = path;
          break;
        } catch (e) {
          lastErr = e;
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
      }
      if (rawAudio == null) {
        throw Exception('Gagal unduh audio.\n$lastErr');
      }

      emit('Kompres audio...', 0.32);
      final smallAudio = p.join(workDir.path, 'audio_small.m4a');
      await _ffmpeg(
        ['-y', '-i', rawAudio, '-c:a', 'aac', '-b:a', '64k', '-ac', '1', smallAudio],
        fallback: ['-y', '-i', rawAudio, '-c:a', 'aac', '-b:a', '64k', smallAudio],
      );
      final transcribeFile =
          await File(smallAudio).exists() ? File(smallAudio) : File(rawAudio);

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
        videoDuration:
            duration.inSeconds > 0 ? duration : const Duration(minutes: 10),
        groqKey: groq,
        geminiKey: gemini,
        youtubeUrl: youtubeUrl,
      );
      if (hooks.isEmpty) {
        throw Exception('AI tidak menemukan hook di video ini.');
      }

      emit('Mengunduh sumber video...', 0.60);
      final mSrc = await yt.getManifest(video.id.value);
      final muxed = yt.muxedAt(mSrc, option.height) ??
          (mSrc.muxed.isEmpty
              ? null
              : (mSrc.muxed.toList()
                    ..sort((a, b) => b.videoResolution.height
                        .compareTo(a.videoResolution.height)))
                  .first);
      final videoOnly = yt.videoOnlyAt(mSrc, option.height);
      final sourcePath = p.join(workDir.path, 'source.mp4');

      if (muxed != null && (videoOnly == null || option.height <= 480)) {
        await ChunkedStreamDownloader.download(
          muxed,
          sourcePath,
          ytForRefresh: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Mengunduh sumber...', 0.60 + 0.18 * f);
          },
        );
      } else if (videoOnly != null) {
        final vPath = p.join(workDir.path, 'source_v.${videoOnly.container.name}');
        await ChunkedStreamDownloader.download(
          videoOnly,
          vPath,
          ytForRefresh: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Mengunduh video...', 0.60 + 0.10 * f);
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final mA = await yt.getManifest(video.id.value);
        final audio = yt.bestAudio(mA);
        if (audio == null) throw Exception('Audio sumber hilang');
        final aPath = p.join(workDir.path, 'source_a.${audio.container.name}');
        await ChunkedStreamDownloader.download(
          audio,
          aPath,
          ytForRefresh: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Mengunduh audio sumber...', 0.70 + 0.08 * f);
          },
        );
        emit('Menggabungkan sumber...', 0.78);
        await _ffmpeg(
          [
            '-y',
            '-i',
            vPath,
            '-i',
            aPath,
            '-c:v',
            'copy',
            '-c:a',
            'copy',
            '-movflags',
            '+faststart',
            sourcePath,
          ],
          fallback: [
            '-y',
            '-i',
            vPath,
            '-i',
            aPath,
            '-c:v',
            'copy',
            '-c:a',
            'aac',
            '-b:a',
            '128k',
            '-movflags',
            '+faststart',
            sourcePath,
          ],
        );
      } else {
        throw Exception('Tidak ada stream video untuk klip.');
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
            '-c:v',
            'copy',
            '-c:a',
            'copy',
            '-movflags',
            '+faststart',
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
            'mpeg4',
            '-q:v',
            '5',
            '-c:a',
            'aac',
            '-b:a',
            '128k',
            '-movflags',
            '+faststart',
            outPath,
          ],
        );
        if (!await File(outPath).exists() || await File(outPath).length() < 1024) {
          throw Exception('Gagal potong klip di $ss');
        }
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
    } finally {
      yt.dispose();
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
