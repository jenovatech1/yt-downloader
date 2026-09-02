import 'dart:io';



import 'package:path/path.dart' as p;

import 'package:path_provider/path_provider.dart';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';



import '../config/get_clip_config.dart';

import '../models/clip_transcript.dart';

import '../models/download_option.dart';

import '../models/download_progress.dart';

import '../models/hook_clip.dart';

import '../utils/format_utils.dart';

import 'api_keys_service.dart';

import 'clip_ai_service.dart';

import 'clip_download_handle.dart';

import 'clip_section_downloader.dart';

import 'yt_dlp_service.dart';

class ClipPipelineResult {
  const ClipPipelineResult({

    required this.clips,

    required this.youtubeUrl,

    required this.sourceTitle,

    required this.transcript,

  });



  final List<HookClip> clips;

  final String youtubeUrl;

  final String sourceTitle;

  final ClipTranscript transcript;

}



class ClipTranscribeResult {

  const ClipTranscribeResult({

    required this.transcript,

    required this.workDir,

    required this.youtubeUrl,

    required this.sourceTitle,

  });



  final ClipTranscript transcript;

  final Directory workDir;

  final String youtubeUrl;

  final String sourceTitle;

}



class ClipPipeline {

  ClipPipeline();



  final _ai = ClipAiService();



  Future<ClipTranscribeResult> transcribeOnly({

    required Video video,

    required void Function(DownloadProgress progress) onProgress,

  }) async {

    final groq = await ApiKeysService.instance.groqKey();

    final gemini = await ApiKeysService.instance.geminiKey();

    if (groq.isEmpty && gemini.isEmpty) {

      throw Exception(

        'Get Clip butuh Groq atau Gemini untuk Whisper. Isi di Pengaturan.',

      );

    }



    void emit(

      String phase,

      double progress, {

      int downloaded = 0,

      int total = 0,

      double speed = 0,

      String? detail,

    }) {

      onProgress(

        DownloadProgress(

          phase: phase,

          progress: progress.clamp(0, 1),

          downloadedBytes: downloaded,

          totalBytes: total,

          speedBytesPerSecond: speed,

          detail: detail,

        ),

      );

    }



    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';

    final workDir = await _prepareWorkDir(video.id.value);



    emit(

      'Mengunduh audio untuk Whisper...',

      0.08,

      detail: 'Langkah 1/2 · audio DASH via yt-dlp',

    );

    final audioPath = await YtDlpService.instance.downloadAudio(

      videoId: video.id.value,

      outputDir: p.join(workDir.path, 'audio'),

      videoDuration: video.duration,

      forTranscribe: true,

      onProgress: (p) => emit(

        p.phase,

        0.08 + 0.42 * p.progress01,

        downloaded: p.downloadedBytes,

        total: p.totalBytes,

        speed: p.speedBytesPerSecond,

      ),

    );



    emit(

      'Transkrip Whisper...',

      0.55,

      downloaded: await File(audioPath).length(),

      total: await File(audioPath).length(),

      detail: 'Langkah 2/2 · kirim audio ke Groq/Gemini',

    );

    final transcript = await _ai.transcribe(

      audioFile: File(audioPath),

      groqKey: groq,

      geminiKey: gemini,

    );

    emit('Transkrip siap', 1, detail: 'Copy prompt ke AI kamu, lalu paste JSON');

    return ClipTranscribeResult(

      transcript: transcript,

      workDir: workDir,

      youtubeUrl: youtubeUrl,

      sourceTitle: video.title,

    );

  }



  Future<ClipPipelineResult> downloadFromHooks({

    required Video video,

    required DownloadOption option,

    required List<HookCandidate> hooks,

    required Directory workDir,

    required ClipTranscript transcript,

    required void Function(DownloadProgress progress) onProgress,

    String? youtubeUrl,

    void Function(HookClip clip)? onClipReady,

    ClipDownloadHandle? cancel,

    void Function()? onClipDownloadStart,

  }) async {

    if (hooks.isEmpty) {

      throw Exception('Tidak ada hook untuk diunduh.');

    }

    final selected = hooks.take(GetClipConfig.maxClips).toList();

    final url =

        youtubeUrl ?? 'https://www.youtube.com/watch?v=${video.id.value}';



    void emit(

      String phase,

      double progress, {

      int downloaded = 0,

      int total = 0,

      double speed = 0,

      String? detail,

    }) {

      onProgress(

        DownloadProgress(

          phase: phase,

          progress: progress.clamp(0, 1),

          downloadedBytes: downloaded,

          totalBytes: total,

          speedBytesPerSecond: speed,

          detail: detail,

        ),

      );

    }



    final clips = <HookClip>[];
    final clipSpan = 0.44;
    final h = option.height.clamp(360, 1080);
    final fullBytes = option.totalBytes;
    final videoDurSec = video.duration?.inSeconds.toDouble() ?? 0;

    int clipEst(HookCandidate hook) => YtDlpService.estimateSectionBytes(
          startSec: hook.startSec,
          endSec: hook.endSec,
          fullVideoBytes: fullBytes,
          videoDurationSec: videoDurSec,
        );

    final totalEst =
        selected.fold<int>(0, (a, hook) => a + clipEst(hook));

    onClipDownloadStart?.call();
    var completedBytes = 0;

    emit(
      'Menyiapkan unduh potongan...',
      0.54,
      total: 0,
      detail: fullBytes > 0
          ? 'Belum unduh data · nanti per klip ~${FormatUtils.bytes(clipEst(selected.first))} '
              '(bukan full ${FormatUtils.bytes(fullBytes)})'
          : 'Belum unduh data · siapkan stream DASH',
    );

    Future<void> addClip(int i, HookCandidate hook, String path) async {
      final stable = p.join(
        workDir.path,
        'clip_${i.toString().padLeft(2, '0')}.mp4',
      );
      if (path != stable) {
        final src = File(path);
        if (await File(stable).exists()) await File(stable).delete();
        await src.copy(stable);
      }
      final size = await File(stable).length();
      completedBytes += size;
      final clip = HookClip(
        index: i,
        startSec: hook.startSec,
        endSec: hook.endSec,
        filePath: stable,
        title: hook.reason,
        hookScore: hook.score,
      );
      clips.add(clip);
      onClipReady?.call(clip);
      emit(
        'Klip ${i + 1}/${selected.length}: selesai',
        0.54 + clipSpan * ((i + 1) / selected.length),
        downloaded: size,
        total: size,
        detail: '${clips.length}/${selected.length} siap',
      );
    }

    await ClipSectionDownloader.instance.beginBatch(
      videoId: video.id.value,
      height: h,
      videoDuration: video.duration,
      onPhase: (phase) => emit(
        phase,
        0.54,
        downloaded: 0,
        total: clipEst(selected.first),
        detail: '$phase · belum unduh byte klip',
      ),
    );

    try {
      for (var i = 0; i < selected.length; i++) {
        if (cancel?.shouldStop == true) break;
        final hook = selected[i];
        final est = clipEst(hook);
        final outDir = p.join(workDir.path, 'clip_$i');
        final clipBase = 0.54 + clipSpan * (i / selected.length);
        final clipFrac = clipSpan / selected.length;
        final path = await ClipSectionDownloader.instance.download(
          videoId: video.id.value,
          height: h,
          sectionStart: hook.startSec,
          sectionEnd: hook.endSec,
          outputDir: outDir,
          estimatedTotalBytes: est,
          videoDuration: video.duration,
          onProgress: (p) {
            emit(
              p.phase,
              clipBase + clipFrac * p.progress01.clamp(0.0, 0.99),
              downloaded: p.downloadedBytes,
              total: est,
              speed: p.speedBytesPerSecond,
              detail: 'Klip ${i + 1}/${selected.length} (potongan ini) · '
                  '${FormatUtils.bytes(p.downloadedBytes)} / '
                  '~${FormatUtils.bytes(est)}',
            );
          },
        );
        await addClip(i, hook, path);
      }
    } finally {
      ClipSectionDownloader.instance.endBatch();
    }

    if (clips.isEmpty) {
      if (cancel?.shouldStop == true) {
        emit('Dibatalkan', 1, detail: 'Tidak ada klip selesai');
        return ClipPipelineResult(
          clips: const [],
          youtubeUrl: url,
          sourceTitle: video.title,
          transcript: transcript.forWindows(const []),
        );
      }
      throw Exception('Tidak ada klip berhasil diunduh.');
    }

    final slimTranscript = transcript.forWindows([
      for (final c in clips) (c.startSec, c.endSec),
    ]);

    final stopped = cancel?.shouldStop == true;
    emit(
      stopped ? 'Dihentikan · ${clips.length} klip' : 'Selesai',
      1,
      downloaded: completedBytes,
      total: totalEst,
      detail: '${clips.length} potongan siap',
    );

    return ClipPipelineResult(

      clips: clips,

      youtubeUrl: url,

      sourceTitle: video.title,

      transcript: slimTranscript,

    );

  }



  Future<ClipPipelineResult> run({

    required Video video,

    required DownloadOption option,

    required void Function(DownloadProgress progress) onProgress,

    void Function(HookClip clip)? onClipReady,

    ClipDownloadHandle? cancel,

    void Function()? onClipDownloadStart,

  }) async {

    final groq = await ApiKeysService.instance.groqKey();

    final gemini = await ApiKeysService.instance.geminiKey();

    final openrouter = await ApiKeysService.instance.openrouterKey();

    final prefer = await ApiKeysService.instance.hookProvider();

    if (groq.isEmpty && gemini.isEmpty) {

      throw Exception(

        'Get Clip butuh Groq atau Gemini untuk Whisper. '

        'OpenRouter hanya untuk cari hook — isi Groq/Gemini di Pengaturan.',

      );

    }

    if (prefer == ClipHookProvider.ownAi) {

      throw Exception('Mode AI sendiri: transcribe dulu, lalu paste hasil AI.');

    }



    void emit(

      String phase,

      double progress, {

      int downloaded = 0,

      int total = 0,

      double speed = 0,

      String? detail,

    }) {

      onProgress(

        DownloadProgress(

          phase: phase,

          progress: progress.clamp(0, 1),

          downloadedBytes: downloaded,

          totalBytes: total,

          speedBytesPerSecond: speed,

          detail: detail,

        ),

      );

    }



    final youtubeUrl = 'https://www.youtube.com/watch?v=${video.id.value}';

    emit('Memulai Get Clip...', 0.01, detail: 'Langkah 1/3 · menyiapkan');

    final workDir = await _prepareWorkDir(video.id.value);



    emit(

      'Mengunduh audio untuk Whisper...',

      0.05,

      detail: 'Langkah 1/3 · audio DASH via yt-dlp',

    );

    final audioPath = await YtDlpService.instance.downloadAudio(

      videoId: video.id.value,

      outputDir: p.join(workDir.path, 'audio'),

      videoDuration: video.duration,

      forTranscribe: true,

      onProgress: (p) => emit(

        p.phase,

        0.05 + 0.28 * p.progress01,

        downloaded: p.downloadedBytes,

        total: p.totalBytes,

        speed: p.speedBytesPerSecond,

        detail: 'Langkah 1/3 · transkrip butuh audio saja',

      ),

    );



    emit(

      'Transkrip Whisper...',

      0.36,

      downloaded: await File(audioPath).length(),

      total: await File(audioPath).length(),

      detail: 'Langkah 2/3 · kirim audio ke Groq/Gemini',

    );

    final transcript = await _ai.transcribe(

      audioFile: File(audioPath),

      groqKey: groq,

      geminiKey: gemini,

    );

    emit(

      'Cari hook (AI)...',

      0.48,

      detail: prefer == ClipHookProvider.openrouter

          ? 'Langkah 2/3 · OpenRouter mencari potongan'

          : 'Langkah 2/3 · pilih potongan viral (${prefer.label})',

    );

    final hooks = await _ai.suggestHooks(

      transcript: transcript.stampedText,

      videoDuration: video.duration ?? const Duration(minutes: 10),

      groqKey: groq,

      geminiKey: gemini,

      openrouterKey: openrouter,

      prefer: prefer,

      youtubeUrl: youtubeUrl,

    );

    if (hooks.isEmpty) {

      throw Exception('AI tidak menemukan hook. Coba video lain.');

    }



    emit('Mengunduh potongan...', 0.5, detail: 'Langkah 3/3');

    return downloadFromHooks(

      video: video,

      option: option,

      hooks: hooks,

      workDir: workDir,

      transcript: transcript,

      onProgress: onProgress,

      youtubeUrl: youtubeUrl,

      onClipReady: onClipReady,

      cancel: cancel,

      onClipDownloadStart: onClipDownloadStart,

    );

  }



  Future<Directory> _prepareWorkDir(String videoId) async {

    final docs = await getApplicationDocumentsDirectory();

    final clipsRoot = Directory(p.join(docs.path, 'clips'));

    if (await clipsRoot.exists()) {

      await clipsRoot.delete(recursive: true);

    }

    final workDir = Directory(p.join(clipsRoot.path, videoId));

    await workDir.create(recursive: true);

    return workDir;

  }

}


