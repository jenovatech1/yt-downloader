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

    var lastBytes = 0;
    var lastTick = DateTime.now();
    var speed = 0.0;

    void emit(
      String phase,
      double progress, {
      int downloaded = 0,
      int total = 0,
    }) {
      final now = DateTime.now();
      final elapsed = now.difference(lastTick).inMilliseconds;
      if (elapsed >= 400 && downloaded >= lastBytes) {
        speed = ((downloaded - lastBytes) * 1000) / elapsed;
        lastTick = now;
        lastBytes = downloaded;
      }
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

    final yt = YoutubeService();
    try {
    emit('Menyiapkan audio (${option.label})...', 0.02);

    final docs = await getApplicationDocumentsDirectory();
    final workDir = Directory(
      p.join(docs.path, 'clips', video.id.value),
    );
    if (await workDir.exists()) {
      await workDir.delete(recursive: true);
    }
    await workDir.create(recursive: true);

    final smallAudio = p.join(workDir.path, 'audio_small.m4a');
    emit('Mengunduh audio...', 0.08);

    // Hanya via youtube_explode get() + manifest fresh (bukan HTTP/FFmpeg URL).
    Object? lastError;
    var ready = false;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        emit(
          attempt == 1 ? 'Mengunduh audio...' : 'Mengunduh audio (ulang $attempt)...',
          0.08,
        );
        final manifest = await yt.getManifest(video.id.value);
        final audio =
            yt.compactAudio(manifest) ?? yt.bestAudio(manifest);
        if (audio == null) throw Exception('Audio stream tidak ada');

        final rawPath = p.join(
          workDir.path,
          'audio_${attempt}.${audio.container.name}',
        );
        await yt.downloadToFile(audio, rawPath, onBytes: (received, total) {
          final frac = total <= 0 ? 0.0 : received / total;
          emit(
            'Mengunduh audio...',
            0.08 + 0.22 * frac,
            downloaded: received,
            total: total,
          );
        });

        emit('Kompres audio...', 0.32);
        await _ffmpeg(
          [
            '-y',
            '-i',
            rawPath,
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
            rawPath,
            '-c:a',
            'aac',
            '-b:a',
            '64k',
            smallAudio,
          ],
        );
        try {
          await File(rawPath).delete();
        } catch (_) {}

        if (await File(smallAudio).exists() &&
            await File(smallAudio).length() > 2048) {
          ready = true;
          break;
        }
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    if (!ready) {
      throw Exception(
        'Gagal mengunduh audio.\n$lastError',
      );
    }

    // Flag muxed vs adaptive untuk potong lokal nanti.
    final cutManifest = await yt.getManifest(video.id.value);
    final videoOnly =
        yt.videoOnlyAt(cutManifest, option.height) ?? option.videoOnly;
    final muxed = yt.muxedAt(cutManifest, option.height) ?? option.muxed;
    final muxedOnly = videoOnly == null && muxed != null;

    final transcribeFile = File(smallAudio);
    emit('Audio siap...', 0.35);

    emit('Transkrip audio (AI)...', 0.40);
    final transcript = await _ai.transcribe(
      audioFile: transcribeFile,
      groqKey: groq,
      geminiKey: gemini,
    );

    final duration = video.duration ?? Duration.zero;
    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';
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

    final clips = <HookClip>[];
    // Potong dari file lokal — FFmpeg ke URL CDN sering hang (throttle).
    emit('Menyiapkan file untuk potong klip...', 0.58);
    final localVideo = p.join(workDir.path, 'source_v.bin');
    final localAudio = p.join(workDir.path, 'source_a.bin');
    var localMuxed = false;
    late final String cutVideoPath;
    String? cutAudioPath;

    if (muxedOnly) {
      final mFresh = await yt.getManifest(video.id.value);
      final mx = yt.muxedAt(mFresh, option.height) ??
          (mFresh.muxed.isEmpty ? null : mFresh.muxed.first);
      if (mx == null) throw Exception('Muxed stream hilang');
      await yt.downloadToFile(mx, localVideo, onBytes: (r, t) {
        final f = t <= 0 ? 0.0 : r / t;
        emit('Mengunduh sumber klip...', 0.58 + 0.05 * f, downloaded: r, total: t);
      });
      cutVideoPath = localVideo;
      localMuxed = true;
    } else {
      final mV = await yt.getManifest(video.id.value);
      final vOnly = yt.videoOnlyAt(mV, option.height) ??
          (mV.videoOnly.isEmpty ? null : mV.videoOnly.first);
      if (vOnly == null) throw Exception('Video stream hilang');
      await yt.downloadToFile(vOnly, localVideo, onBytes: (r, t) {
        final f = t <= 0 ? 0.0 : r / t;
        emit('Mengunduh video sumber...', 0.58 + 0.03 * f, downloaded: r, total: t);
      });
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final mA = await yt.getManifest(video.id.value);
      final aOnly = yt.bestAudio(mA);
      if (aOnly == null) throw Exception('Audio stream hilang');
      await yt.downloadToFile(aOnly, localAudio, onBytes: (r, t) {
        final f = t <= 0 ? 0.0 : r / t;
        emit('Mengunduh audio sumber...', 0.61 + 0.02 * f, downloaded: r, total: t);
      });
      cutVideoPath = localVideo;
      cutAudioPath = localAudio;
    }

    for (var i = 0; i < hooks.length; i++) {
      final hook = hooks[i];
      final start = hook.startSec;
      final dur = hook.endSec - hook.startSec;
      emit(
        'Memotong klip ${i + 1}/${hooks.length}...',
        0.64 + 0.34 * (i / hooks.length),
      );
      final outPath = p.join(
        workDir.path,
        'clip_${i.toString().padLeft(2, '0')}.mp4',
      );
      await _cutSegment(
        videoUrl: cutVideoPath,
        audioUrl: cutAudioPath ?? cutVideoPath,
        startSec: start,
        durationSec: dur,
        outputPath: outPath,
        muxedOnly: localMuxed,
      );
      clips.add(
        HookClip(
          index: i,
          startSec: start,
          endSec: hook.endSec,
          filePath: outPath,
          title: hook.reason ?? 'Klip ${i + 1}',
          hookScore: hook.score,
        ),
      );
    }

    try {
      if (await File(smallAudio).exists()) await File(smallAudio).delete();
      if (await File(localVideo).exists()) await File(localVideo).delete();
      if (await File(localAudio).exists()) await File(localAudio).delete();
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
    } finally {
      yt.dispose();
    }
  }

  Future<void> _cutSegment({
    required String videoUrl,
    required String audioUrl,
    required double startSec,
    required double durationSec,
    required String outputPath,
    required bool muxedOnly,
  }) async {
    final ss = startSec.toStringAsFixed(3);
    final t = durationSec.toStringAsFixed(3);
    if (muxedOnly) {
      await _ffmpeg(
        [
          '-y',
          '-user_agent',
          'com.google.android.youtube/19.09.37 (Linux; U; Android 14) gzip',
          '-ss', ss,
          '-t', t,
          '-i', videoUrl,
          '-c:v', 'copy',
          '-c:a', 'copy',
          '-movflags', '+faststart',
          outputPath,
        ],
        fallback: [
          '-y',
          '-ss', ss,
          '-t', t,
          '-i', videoUrl,
          '-c:v', 'mpeg4',
          '-q:v', '5',
          '-c:a', 'aac',
          '-b:a', '128k',
          '-movflags', '+faststart',
          outputPath,
        ],
      );
    } else {
      await _ffmpeg(
        [
          '-y',
          '-user_agent',
          'com.google.android.youtube/19.09.37 (Linux; U; Android 14) gzip',
          '-ss', ss,
          '-t', t,
          '-i', videoUrl,
          '-ss', ss,
          '-t', t,
          '-i', audioUrl,
          '-c:v', 'copy',
          '-c:a', 'copy',
          '-shortest',
          '-movflags', '+faststart',
          outputPath,
        ],
        fallback: [
          '-y',
          '-ss', ss,
          '-t', t,
          '-i', videoUrl,
          '-ss', ss,
          '-t', t,
          '-i', audioUrl,
          '-c:v', 'mpeg4',
          '-q:v', '5',
          '-c:a', 'aac',
          '-b:a', '128k',
          '-shortest',
          '-movflags', '+faststart',
          outputPath,
        ],
      );
    }
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
