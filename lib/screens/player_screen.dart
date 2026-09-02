import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/clip_transcript.dart';
import '../models/download_option.dart';
import '../models/download_progress.dart';
import '../models/hook_clip.dart';
import '../config/get_clip_config.dart';
import '../screens/clip_preview_screen.dart';
import '../screens/settings_screen.dart';
import '../services/api_keys_service.dart';
import '../services/clip_ai_service.dart';
import '../services/clip_download_handle.dart';
import '../services/clip_pipeline.dart';
import '../services/download_manager.dart';
import '../services/klippod_launcher.dart';
import '../services/yt_dlp_service.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../widgets/download_progress_card.dart';
import '../services/own_ai_clip.dart';
import '../widgets/own_ai_clip_panel.dart';
import '../widgets/youtube_style_player.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.video});

  final Video video;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _youtube = YoutubeService();
  final _downloadManager = DownloadManager.instance;

  VideoPlayerController? _controller;
  List<DownloadOption> _options = [];
  DownloadOption? _selected;

  bool _loadingPlayer = true;
  bool _loadingOptions = true;
  bool _downloading = false;
  bool _downloadDone = false;
  bool _clipping = false;
  bool _openingKlippod = false;
  DownloadProgress _progress = DownloadProgress.idle;
  List<HookClip> _clips = [];
  String? _clipsYoutubeUrl;
  ClipTranscript? _clipsTranscript;
  String? _playerError;
  String? _optionsError;
  StreamSubscription<DownloadProgress>? _progressSub;
  final _klippod = KlippodLauncher();
  ClipTranscribeResult? _ownAiTranscribe;
  String? _ownAiExport;
  bool _ownAiApplying = false;
  ClipDownloadHandle? _clipCancel;
  bool _clipDownloading = false;

  @override
  void initState() {
    super.initState();
    unawaited(YtDlpService.instance.ensureReady());
    _progressSub = _downloadManager.progressStream.listen((progress) {
      if (!mounted) return;
      setState(() {
        _progress = progress;
        if (progress.isDone || progress.error != null) {
          _downloading = false;
        }
        if (progress.isDone) {
          _downloadDone = true;
        }
      });

      if (progress.isDone) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Selesai (${_selected?.label ?? ''}) · membuka Klippod...',
            ),
          ),
        );
      } else if (progress.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download gagal: ${progress.error}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    });
    _downloading = _downloadManager.isRunning;
    _progress = _downloadManager.latest;
    _init();
  }

  Future<void> _init() async {
    await Future.wait([_initPlayer(), _loadOptions()]);
  }

  Future<void> _initPlayer() async {
    try {
      final url = await _youtube.getPlayableUrl(widget.video.id.value);
      if (!mounted) return;
      if (url == null) {
        setState(() {
          _loadingPlayer = false;
          _playerError = 'Stream play tidak tersedia untuk video ini';
        });
        return;
      }

      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loadingPlayer = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPlayer = false;
        _playerError = 'Gagal memutar video: ${YoutubeService.shortError(e)}';
      });
    }
  }

  Future<void> _loadOptions() async {
    try {
      final options = await _youtube.getDownloadOptions(widget.video.id.value);
      if (!mounted) return;
      setState(() {
        _options = options;
        _selected = options.isNotEmpty ? options.first : null;
        _loadingOptions = false;
        if (options.isEmpty) {
          _optionsError = 'Tidak ada kualitas unduhan tersedia';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingOptions = false;
        _optionsError =
            'Gagal memuat kualitas: ${YoutubeService.shortError(e)}';
      });
    }
  }

  Future<void> _releasePlayer() async {
    final player = _controller;
    _controller = null;
    if (player == null) return;
    try {
      await player.pause();
    } catch (_) {}
    try {
      await player.dispose();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _download() async {
    final option = _selected;
    if (option == null || _downloading || _downloadManager.isRunning) return;

    setState(() {
      _downloading = true;
      _downloadDone = false;
      _progress = const DownloadProgress(
        phase: 'Menyiapkan...',
        progress: 0,
        downloadedBytes: 0,
        totalBytes: 0,
        speedBytesPerSecond: 0,
      );
    });

    try {
      // Lepas player total — koneksi googlevideo player sering bikin download hang.
      await _releasePlayer();

      await _downloadManager.startDownload(video: widget.video, option: option);

      if (!mounted) return;
      setState(() => _downloadDone = true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _openInKlippod(auto: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Download gagal: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted && !_downloadManager.isRunning) {
        setState(() => _downloading = false);
      }
    }
  }

  bool get _busy => _downloading || _clipping || _downloadManager.isRunning;

  Future<void> _getClip() async {
    final option = _selected;
    if (option == null || _busy) return;
    final provider = await ApiKeysService.instance.hookProvider();
    if (!mounted) return;

    final needsWhisper = await ApiKeysService.instance.hasWhisperKey();
    if (!mounted) return;
    if (!needsWhisper) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('API key belum diisi'),
          content: const Text(
            'Get Clip butuh Groq dan/atau Gemini untuk Whisper. Isi dulu di Pengaturan.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Nanti'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Pengaturan'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      }
      return;
    }

    if (provider != ClipHookProvider.ownAi) {
      final hasHookKey = await ApiKeysService.instance.hasAnyKey();
      if (!mounted) return;
      if (!hasHookKey) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Isi minimal satu API key di Pengaturan.'),
          ),
        );
        return;
      }
    }

    setState(() {
      _clipping = true;
      _clipDownloading = false;
      _clipCancel = ClipDownloadHandle();
      _clips = [];
      _clipsTranscript = null;
      _ownAiTranscribe = null;
      _ownAiExport = null;
      _progress = DownloadProgress(
        phase: provider == ClipHookProvider.ownAi
            ? 'Menyiapkan transcribe...'
            : 'Menyiapkan Get Clip...',
        progress: 0,
        downloadedBytes: 0,
        totalBytes: 0,
        speedBytesPerSecond: 0,
        detail: provider == ClipHookProvider.ownAi
            ? 'AI sendiri: transcribe dulu, paste JSON setelahnya'
            : 'Hanya potongan hook · bukan unduh video full',
      );
    });

    await _releasePlayer();

    try {
      if (provider == ClipHookProvider.ownAi) {
        final transcribed = await ClipPipeline().transcribeOnly(
          video: widget.video,
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress);
          },
        );
        if (!mounted) return;
        final export = buildOwnAiExportFile(
          transcript: formatTimedTranscript(transcribed.transcript.cues),
          videoTitle: widget.video.title,
          durationSeconds: widget.video.duration?.inSeconds,
        );
        setState(() {
          _ownAiTranscribe = transcribed;
          _ownAiExport = export;
          _clipping = false;
        });
        return;
      }

      final result = await ClipPipeline().run(
        video: widget.video,
        option: option,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
        onClipDownloadStart: () {
          if (!mounted) return;
          setState(() => _clipDownloading = true);
        },
        onClipReady: (clip) {
          if (!mounted) return;
          setState(() => _clips = [..._clips, clip]);
        },
        cancel: _clipCancel,
      );
      if (!mounted) return;
      final wasStopped = _clipCancel?.shouldStop == true;
      setState(() {
        _clips = result.clips;
        _clipsYoutubeUrl = result.youtubeUrl;
        _clipsTranscript = result.transcript;
        _clipping = false;
        _clipDownloading = false;
        _clipCancel = null;
      });
      if (result.clips.isEmpty && wasStopped) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasStopped
                ? 'Dihentikan · ${result.clips.length} potongan siap.'
                : '${result.clips.length} potongan siap (bukan video full). '
                      'Buka di Klippod untuk render.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _clipping = false;
        _clipDownloading = false;
        _clipCancel = null;
      });
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Get Clip gagal: ${YoutubeService.shortError(e)}'),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(days: 1),
          showCloseIcon: true,
        ),
      );
    }
  }

  Future<void> _applyOwnAiClips(String paste) async {
    final option = _selected;
    final transcribed = _ownAiTranscribe;
    if (option == null || transcribed == null || _busy) return;

    final parsed = parseOwnAiClipPaste(paste);
    if (!parsed.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(parsed.error ?? 'JSON tidak valid'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    final hooks = ClipAiService.parseHooks(
      paste,
      widget.video.duration ?? const Duration(hours: 10),
    );
    if (hooks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(parsed.error ?? 'Tidak ada clip valid di paste.'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    setState(() {
      _ownAiApplying = true;
      _clipping = true;
      _clipDownloading = false;
      _clipCancel = ClipDownloadHandle();
      _clips = [];
      _progress = const DownloadProgress(
        phase: 'Mengunduh potongan...',
        progress: 0,
        downloadedBytes: 0,
        totalBytes: 0,
        speedBytesPerSecond: 0,
      );
    });

    try {
      final result = await ClipPipeline().downloadFromHooks(
        video: widget.video,
        option: option,
        hooks: hooks,
        workDir: transcribed.workDir,
        transcript: transcribed.transcript,
        youtubeUrl: transcribed.youtubeUrl,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
        onClipDownloadStart: () {
          if (!mounted) return;
          setState(() => _clipDownloading = true);
        },
        onClipReady: (clip) {
          if (!mounted) return;
          setState(() => _clips = [..._clips, clip]);
        },
        cancel: _clipCancel,
      );
      if (!mounted) return;
      final wasStopped = _clipCancel?.shouldStop == true;
      setState(() {
        _clips = result.clips;
        _clipsYoutubeUrl = result.youtubeUrl;
        _clipsTranscript = result.transcript;
        _ownAiTranscribe = null;
        _ownAiExport = null;
        _clipping = false;
        _ownAiApplying = false;
        _clipDownloading = false;
        _clipCancel = null;
      });
      if (result.clips.isEmpty && wasStopped) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasStopped
                ? 'Dihentikan · ${result.clips.length} potongan siap.'
                : '${result.clips.length} potongan siap.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _clipping = false;
        _ownAiApplying = false;
        _clipDownloading = false;
        _clipCancel = null;
      });
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Get Clip gagal: ${YoutubeService.shortError(e)}'),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(days: 1),
          showCloseIcon: true,
        ),
      );
    }
  }

  void _stopClipDownload() {
    if (_clipCancel == null) return;
    _clipCancel!.requestStop();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _clips.isEmpty
              ? 'Menghentikan unduhan...'
              : 'Menghentikan setelah klip ${_clips.length} selesai...',
        ),
      ),
    );
  }

  Future<void> _openClipsInKlippod() async {
    if (_clips.isEmpty || _openingKlippod) return;
    setState(() => _openingKlippod = true);
    try {
      final hooksJson = jsonEncode({
        'schemaVersion': 3,
        'source': 'yt_downloader',
        'sourceTitle': widget.video.title,
        'youtubeUrl':
            _clipsYoutubeUrl ??
            'https://www.youtube.com/watch?v=${widget.video.id.value}',
        'skipDetect': true,
        'skipWhisper': true,
        if (_clipsTranscript != null) 'transcript': _clipsTranscript!.toJson(),
        'clips': [
          for (final clip in _clips)
            {
              'index': clip.index,
              'title': clip.title,
              'hookScore': clip.hookScore,
              'startSec': clip.startSec,
              'endSec': clip.endSec,
              'fileName': clip.filePath.split(RegExp(r'[\\/]')).last,
            },
        ],
      });
      final outcome = await _klippod.openClips(
        filePaths: _clips.map((c) => c.filePath).toList(),
        title: widget.video.title,
        youtubeUrl:
            _clipsYoutubeUrl ??
            'https://www.youtube.com/watch?v=${widget.video.id.value}',
        hooksJson: hooksJson,
      );
      if (!mounted) return;
      await _handleKlippodOutcome(outcome);
    } finally {
      if (mounted) setState(() => _openingKlippod = false);
    }
  }

  Future<void> _openInKlippod({bool auto = false}) async {
    final path = _downloadManager.lastExportedPath;
    if (path == null) {
      if (!mounted || auto) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('File video belum siap')));
      return;
    }

    // Pastikan file final ada & tidak kosong (audio+video sudah lengkap).
    final file = File(path);
    if (!await file.exists() || await file.length() < 1024) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File video belum lengkap, coba buka lagi'),
        ),
      );
      return;
    }

    if (_openingKlippod) return;
    setState(() => _openingKlippod = true);
    try {
      final outcome = await _klippod.openVideo(
        filePath: path,
        title: _downloadManager.lastExportedTitle ?? widget.video.title,
      );
      if (!mounted) return;
      await _handleKlippodOutcome(outcome);
    } finally {
      if (mounted) setState(() => _openingKlippod = false);
    }
  }

  Future<void> _handleKlippodOutcome(KlippodOpenOutcome outcome) async {
    switch (outcome.result) {
      case KlippodOpenResult.opened:
        break;
      case KlippodOpenResult.notInstalled:
        final install = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Klippod belum terpasang'),
            content: const Text(
              'Install Klippod dari Play Store supaya video bisa langsung dibuka di sana.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Nanti'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Install'),
              ),
            ],
          ),
        );
        if (install == true) {
          await _klippod.openPlayStore();
        }
      case KlippodOpenResult.fileMissing:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(outcome.message ?? 'File video tidak ditemukan'),
          ),
        );
      case KlippodOpenResult.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(outcome.message ?? 'Gagal membuka Klippod'),
            duration: const Duration(seconds: 6),
          ),
        );
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _controller?.dispose();
    _youtube.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final video = widget.video;

    final bottomSafe = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Putar, Download, Klip'),
        actions: [
          IconButton(
            tooltip: 'Pengaturan API key',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 48 + bottomSafe),
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: _buildPlayer(theme)),
          const SizedBox(height: 16),
          Text(
            video.title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${video.author}  ·  ${FormatUtils.duration(video.duration ?? Duration.zero)}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Kualitas',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Dipakai Download dan Get Clip · pilih dulu sebelum mulai',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.18),
              ),
            ),
            child: Text(
              'Get Clip: maks ${GetClipConfig.maxClips} potongan · '
              '${GetClipConfig.durationPrompt} per klip · bukan video full. '
              'Whisper ikut dikirim ke Klippod.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_loadingOptions)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_optionsError != null)
            Text(
              _optionsError!,
              style: TextStyle(color: theme.colorScheme.error),
            )
          else if (_options.isEmpty)
            Text(
              'Tidak ada kualitas unduhan tersedia',
              style: TextStyle(color: theme.colorScheme.error),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _options.map((option) {
                final selected =
                    _selected?.height == option.height &&
                    _selected?.isMuxed == option.isMuxed;
                return ChoiceChip(
                  label: Text('${option.label} · ${option.sizeLabel}'),
                  selected: selected,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() => _selected = option),
                );
              }).toList(),
            ),
          const SizedBox(height: 24),
          if ((_downloading || _clipping) && _progress.phase.isNotEmpty)
            DownloadProgressCard(
              progress: _progress,
              tip: _clipDownloading
                  ? 'Unduh per klip (DASH fragment) — bukan video full. '
                        'Angka MB = satu potongan hook saja.'
                  : _clipping
                  ? 'Langkah 1–2: audio & AI. Unduhan klip (per potongan) setelah ini.'
                  : null,
            ),
          if (_clipDownloading) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _stopClipDownload,
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(
                _clips.isEmpty
                    ? 'Batalkan unduhan klip'
                    : 'Stop · pakai ${_clips.length} klip',
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(
                  color: theme.colorScheme.error.withValues(alpha: 0.6),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
          if ((_downloading || _clipping) && _progress.phase.isNotEmpty)
            const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_selected == null || _busy || _loadingOptions)
                      ? null
                      : _download,
                  icon: _downloading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.download_rounded),
                  label: Text(_downloading ? 'Download...' : 'Download'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_selected == null || _busy || _loadingOptions)
                      ? null
                      : _getClip,
                  icon: _clipping
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.content_cut_rounded),
                  label: Text(
                    _clipping
                        ? 'Get Clip...'
                        : _selected != null
                        ? 'Get Clip (${_selected!.label})'
                        : 'Get Clip',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_downloadDone && _downloadManager.lastExportedPath != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openingKlippod ? null : () => _openInKlippod(),
              icon: _openingKlippod
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cut_rounded),
              label: Text(
                _openingKlippod ? 'Membuka Klippod...' : 'Buka lagi di Klippod',
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
          if (_ownAiExport != null) ...[
            const SizedBox(height: 16),
            OwnAiClipPanel(
              exportText: _ownAiExport,
              exportFileName: ownAiExportFileName(widget.video.title),
              applying: _ownAiApplying,
              onApply: _applyOwnAiClips,
            ),
          ],
          if (_clips.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              _clipDownloading
                  ? 'Klip siap (${_clips.length} · masih mengunduh...)'
                  : 'Klip siap (${_clips.length})',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ketuk klip untuk pratinjau · Stop kapan saja kalau sudah cukup.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ..._clips.map(
              (clip) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                    child: Text('${clip.index + 1}'),
                  ),
                  title: Text(clip.title ?? 'Klip ${clip.index + 1}'),
                  subtitle: Text(
                    '${FormatUtils.duration(Duration(seconds: clip.startSec.round()))}'
                    ' – ${FormatUtils.duration(Duration(seconds: clip.endSec.round()))}'
                    '${clip.hookScore != null ? ' · skor ${clip.hookScore!.round()}' : ''}',
                  ),
                  trailing: const Icon(Icons.play_circle_outline_rounded),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ClipPreviewScreen(clip: clip),
                      ),
                    );
                  },
                ),
              ),
            ),
            if (!_clipDownloading && _clips.isNotEmpty) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _openingKlippod ? null : _openClipsInKlippod,
                icon: _openingKlippod
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.open_in_new_rounded),
                label: Text(
                  _openingKlippod
                      ? 'Membuka Klippod...'
                      : 'Open clip di Klippod',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildPlayer(ThemeData theme) {
    if (_loadingPlayer) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: const ColoredBox(
          color: Colors.black,
          child: Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          ),
        ),
      );
    }

    if (_playerError != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.white70),
                  const SizedBox(height: 8),
                  Text(
                    _playerError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return YoutubeStylePlayer(controller: controller);
  }
}
