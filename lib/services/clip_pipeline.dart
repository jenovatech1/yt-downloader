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
import 'youtube_service.dart';
import 'yt_stream_downloader.dart';

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
    final docs = await getApplicationDocumentsDirectory();
    final workDir = Directory(p.join(docs.path, 'clips', video.id.value));
    if (await workDir.exists()) await workDir.delete(recursive: true);
    await workDir.create(recursive: true);

    try {
      emit('Mengunduh audio...', 0.08);
      final m0 = await yt.getManifest(video.id.value);
      final muxForAudio = m0.muxed.isEmpty
          ? null
          : (m0.muxed.toList()
                ..sort((a, b) => a.size.totalBytes.compareTo(b.size.totalBytes)))
              .first;
      final hlsAudio = yt.hlsAudio(m0);

      final smallAudio = p.join(workDir.path, 'audio_small.m4a');
      if (hlsAudio != null) {
        final aPath = p.join(workDir.path, 'hls_a.ts');
        await YtStreamDownloader.download(
          hlsAudio,
          aPath,
          yt: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Mengunduh audio HLS...', 0.08 + 0.18 * f);
          },
        );
        await _ffmpeg([
          '-y', '-i', aPath, '-vn', '-c:a', 'aac', '-b:a', '64k',
          '-ac', '1', '-ar', '16000', smallAudio,
        ]);
      } else if (muxForAudio != null) {
        final muxPath = p.join(workDir.path, 'mux_audio_src.mp4');
        await YtStreamDownloader.download(
          muxForAudio,
          muxPath,
          yt: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Mengunduh audio...', 0.08 + 0.18 * f);
          },
        );
        await _ffmpeg([
          '-y', '-i', muxPath, '-vn', '-c:a', 'aac', '-b:a', '64k',
          '-ac', '1', '-ar', '16000', smallAudio,
        ]);
      } else {
        throw Exception('Tidak ada stream audio.');
      }

      emit('Transkrip audio (AI)...', 0.35);
      final transcript = await _ai.transcribe(
        audioFile: File(smallAudio),
        groqKey: groq,
        geminiKey: gemini,
      );
      emit('Cari hook (AI)...', 0.45);
      final hooks = await _ai.suggestHooks(
        transcript: transcript,
        videoDuration: video.duration ?? const Duration(minutes: 10),
        groqKey: groq,
        geminiKey: gemini,
        youtubeUrl: youtubeUrl,
      );
      if (hooks.isEmpty) {
        throw Exception('AI tidak menemukan hook.');
      }

      emit('Mengunduh sumber video...', 0.55);
      final m1 = await yt.getManifest(video.id.value);
      final sourcePath = p.join(workDir.path, 'source.mp4');
      final height = option.height.clamp(360, 1080);
      final hlsV = yt.hlsVideoClosest(m1, height);
      final hlsA = yt.hlsAudio(m1);
      final videoOnly = yt.videoOnlyAt(m1, height) ??
          yt.videoOnlyAt(m1, 720) ??
          yt.videoOnlyAt(m1, 480);
      final audioOnly = yt.bestAudio(m1);
      final muxed = yt.muxedAt(m1, height) ??
          (m1.muxed.isEmpty
              ? null
              : (m1.muxed.toList()
                    ..sort((a, b) => b.videoResolution.height
                        .compareTo(a.videoResolution.height)))
                  .first);

      if (hlsV != null && hlsA != null) {
        final vPath = p.join(workDir.path, 'src_v.ts');
        final aPath = p.join(workDir.path, 'src_a.ts');
        try {
          await YtStreamDownloader.download(
            hlsV,
            vPath,
            yt: yt.client,
            onBytes: (r, t) {
              final f = t <= 0 ? 0.0 : r / t;
              emit('Video sumber HLS...', 0.55 + 0.12 * f);
            },
          );
          await YtStreamDownloader.download(
            hlsA,
            aPath,
            yt: yt.client,
            onBytes: (r, t) {
              final f = t <= 0 ? 0.0 : r / t;
              emit('Audio sumber HLS...', 0.67 + 0.08 * f);
            },
          );
          await _ffmpeg([
            '-y', '-i', vPath, '-i', aPath,
            '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
            '-movflags', '+faststart', sourcePath,
          ]);
        } catch (_) {
          if (videoOnly == null || audioOnly == null) rethrow;
          final v2 = p.join(workDir.path, 'src_v.${videoOnly.container.name}');
          final a2 = p.join(workDir.path, 'src_a.${audioOnly.container.name}');
          await YtStreamDownloader.download(
            videoOnly,
            v2,
            yt: yt.client,
            onBytes: (r, t) {
              final f = t <= 0 ? 0.0 : r / t;
              emit('Video sumber...', 0.55 + 0.12 * f);
            },
          );
          await YtStreamDownloader.download(
            audioOnly,
            a2,
            yt: yt.client,
            onBytes: (r, t) {
              final f = t <= 0 ? 0.0 : r / t;
              emit('Audio sumber...', 0.67 + 0.08 * f);
            },
          );
          await _ffmpeg([
            '-y', '-i', v2, '-i', a2,
            '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
            '-movflags', '+faststart', sourcePath,
          ]);
        }
      } else if (videoOnly != null && audioOnly != null) {
        final vPath = p.join(workDir.path, 'src_v.${videoOnly.container.name}');
        final aPath = p.join(workDir.path, 'src_a.${audioOnly.container.name}');
        await YtStreamDownloader.download(
          videoOnly,
          vPath,
          yt: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Video sumber...', 0.55 + 0.12 * f);
          },
        );
        await YtStreamDownloader.download(
          audioOnly,
          aPath,
          yt: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Audio sumber...', 0.67 + 0.08 * f);
          },
        );
        await _ffmpeg([
          '-y', '-i', vPath, '-i', aPath,
          '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
          '-movflags', '+faststart', sourcePath,
        ]);
      } else if (muxed != null) {
        await YtStreamDownloader.download(
          muxed,
          sourcePath,
          yt: yt.client,
          onBytes: (r, t) {
            final f = t <= 0 ? 0.0 : r / t;
            emit('Mengunduh sumber...', 0.55 + 0.20 * f);
          },
        );
      } else {
        throw Exception('Tidak ada stream sumber HD.');
      }

      final clips = <HookClip>[];
      for (var i = 0; i < hooks.length; i++) {
        final hook = hooks[i];
        emit(
          'Memotong klip ${i + 1}/${hooks.length}...',
          0.78 + 0.18 * (i / hooks.length),
        );
        final outPath = p.join(
          workDir.path,
          'clip_${i.toString().padLeft(2, '0')}.mp4',
        );
        final ss = hook.startSec.toStringAsFixed(3);
        final t = (hook.endSec - hook.startSec).toStringAsFixed(3);
        await _ffmpeg([
          '-y', '-ss', ss, '-t', t, '-i', sourcePath,
          '-c', 'copy', '-avoid_negative_ts', 'make_zero', outPath,
        ], fallback: [
          '-y', '-ss', ss, '-t', t, '-i', sourcePath,
          '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k', outPath,
        ]);
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
