import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/download_progress.dart';
import '../utils/format_utils.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const channelId = 'yt_download_channel';
  static const channelName = 'Download Video';
  /// ID FGS + progress (jangan dipakai untuk notif selesai).
  static const downloadNotificationId = 888;
  static const completedNotificationId = 889;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings: settings);

    const channel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: 'Progress download video ke galeri',
      importance: Importance.low,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _initialized = true;
  }

  Future<void> showDownloadProgress({
    required String title,
    required DownloadProgress progress,
  }) async {
    await init();

    final downloaded = FormatUtils.bytes(progress.downloadedBytes);
    final total = FormatUtils.bytes(progress.totalBytes);
    final remaining = FormatUtils.bytes(progress.remainingBytes);
    final speed = FormatUtils.speedMBps(progress.speedBytesPerSecond);
    final percent = FormatUtils.percent(progress.progress);

    await _plugin.show(
      id: downloadNotificationId,
      title: 'Mengunduh: $title',
      body:
          '$percent · $speed · $downloaded / $total · sisa $remaining',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'Progress download video ke galeri',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: 100,
          progress: (progress.progress * 100).clamp(0, 100).round(),
          ongoing: true,
          autoCancel: false,
        ),
      ),
    );
  }

  Future<void> showCompleted(String title, String quality) async {
    await init();
    await cancelDownloadNotification();
    await _plugin.show(
      id: completedNotificationId,
      title: 'Download selesai',
      body: '$title ($quality) tersimpan ke galeri',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          autoCancel: true,
          ongoing: false,
        ),
      ),
    );
  }

  Future<void> showError(String title, String message) async {
    await init();
    await cancelDownloadNotification();
    await _plugin.show(
      id: completedNotificationId,
      title: 'Download gagal',
      body: '$title — $message',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
          ongoing: false,
        ),
      ),
    );
  }

  Future<void> cancelDownloadNotification() async {
    await _plugin.cancel(id: downloadNotificationId);
    // Bersihkan notif lama (versi sebelumnya pakai id 1001).
    await _plugin.cancel(id: 1001);
  }
}
