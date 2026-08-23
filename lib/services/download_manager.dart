import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:gal/gal.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';
import '../models/download_progress.dart';
import '../utils/format_utils.dart';
import 'download_service.dart';
import 'notification_service.dart';
import 'youtube_service.dart';

class DownloadManager with WidgetsBindingObserver {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  late final DownloadService _downloader = DownloadService(YoutubeService());
  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  DownloadProgress _latest = DownloadProgress.idle;
  DownloadProgress get latest => _latest;

  bool _running = false;
  bool get isRunning => _running;
  bool _observerRegistered = false;
  bool _foregroundServiceActive = false;
  String _currentTitle = '';
  String? lastExportedPath;
  String? lastExportedTitle;
  DateTime _lastNotifUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> initialize() async {
    await NotificationService.instance.init();
    await _configureBackgroundService();
    _registerLifecycleObserver();
  }

  void _registerLifecycleObserver() {
    if (_observerRegistered) return;
    WidgetsBinding.instance.addObserver(this);
    _observerRegistered = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_running) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      unawaited(_ensureForegroundService());
    }
  }

  Future<void> _configureBackgroundService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onBackgroundStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: NotificationService.channelId,
        foregroundServiceNotificationId:
            NotificationService.downloadNotificationId,
        initialNotificationTitle: 'YT Downloader',
        initialNotificationContent: 'Mengunduh video...',
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(),
    );
  }

  Future<void> startDownload({
    required Video video,
    required DownloadOption option,
  }) async {
    if (_running) {
      throw Exception('Download lain masih berjalan');
    }

    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        throw Exception('Izin akses galeri ditolak');
      }
    }

    _running = true;
    _currentTitle = video.title;
    _lastNotifUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    _emit(
      DownloadProgress(
        phase: 'Menyiapkan...',
        progress: 0,
        downloadedBytes: 0,
        totalBytes: option.totalBytes,
        speedBytesPerSecond: 0,
      ),
      forceNotif: true,
    );

    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.inactive) {
      await _ensureForegroundService();
    }

    try {
      final exportPath = await _downloader.runJob(
        video: video,
        option: option,
        onProgress: _emit,
      );
      lastExportedPath = exportPath;
      lastExportedTitle = video.title;

      await _stopForegroundService();
      await NotificationService.instance.showCompleted(
        video.title,
        option.label,
      );

      _emit(
        DownloadProgress(
          phase: 'Selesai',
          progress: 1,
          downloadedBytes: option.totalBytes,
          totalBytes: option.totalBytes,
          speedBytesPerSecond: 0,
          isDone: true,
        ),
        forceNotif: true,
      );
    } catch (e) {
      await _stopForegroundService();
      await NotificationService.instance.showError(video.title, '$e');

      _emit(
        DownloadProgress(
          phase: 'Gagal',
          progress: 0,
          downloadedBytes: 0,
          totalBytes: option.totalBytes,
          speedBytesPerSecond: 0,
          error: '$e',
        ),
        forceNotif: true,
      );
      rethrow;
    } finally {
      _running = false;
      _foregroundServiceActive = false;
    }
  }

  Future<void> _ensureForegroundService() async {
    if (_foregroundServiceActive) return;

    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    _foregroundServiceActive = true;

    if (_latest.phase.isNotEmpty) {
      _pushForegroundNotification(_latest, force: true);
    }
  }

  Future<void> _stopForegroundService() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('stopService');
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!await service.isRunning()) break;
      }
    }
    _foregroundServiceActive = false;
    await NotificationService.instance.cancelDownloadNotification();
  }

  void _emit(DownloadProgress progress, {bool forceNotif = false}) {
    _latest = progress;
    _progressController.add(progress);

    if (progress.isDone || progress.error != null) return;
    _pushForegroundNotification(progress, force: forceNotif);
  }

  void _pushForegroundNotification(
    DownloadProgress progress, {
    bool force = false,
  }) {
    if (!_foregroundServiceActive) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastNotifUpdate).inMilliseconds < 1000) {
      return;
    }
    _lastNotifUpdate = now;

    final short = _currentTitle.length > 40
        ? '${_currentTitle.substring(0, 40)}…'
        : _currentTitle;

    FlutterBackgroundService().invoke('updateNotification', {
      'title': 'Mengunduh: $short',
      'content':
          '${progress.phase} · ${FormatUtils.percent(progress.progress)} · ${FormatUtils.speedMBps(progress.speedBytesPerSecond)} · ${FormatUtils.bytes(progress.downloadedBytes)}/${FormatUtils.bytes(progress.totalBytes)}',
    });
  }

  @pragma('vm:entry-point')
  static Future<void> _onBackgroundStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }

    service.on('updateNotification').listen((event) {
      if (event == null || service is! AndroidServiceInstance) return;
      service.setForegroundNotificationInfo(
        title: event['title'] as String? ?? 'YT Downloader',
        content: event['content'] as String? ?? 'Mengunduh...',
      );
    });

    service.on('stopService').listen((_) {
      service.stopSelf();
    });
  }
}
