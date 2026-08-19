import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../config/update_config.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    this.notes = '',
  });

  final String version;
  final int versionCode;
  final String apkUrl;
  final String notes;
}

class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const _channel = MethodChannel('yt_downloader/updater');

  final ValueNotifier<AppUpdateInfo?> available = ValueNotifier(null);

  String currentVersion = '';
  int currentVersionCode = 0;
  bool _checking = false;
  bool _installing = false;

  Future<AppUpdateInfo?> check() async {
    if (_checking) return available.value;
    _checking = true;
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
      currentVersionCode = int.tryParse(info.buildNumber) ?? 0;

      final client = HttpClient();
      client.userAgent = 'yt-downloader';
      try {
        final request = await client.getUrl(Uri.parse(UpdateConfig.latestJsonUrl));
        final response = await request.close().timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) return available.value;

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final remoteCode = (json['versionCode'] as num?)?.toInt() ?? 0;
        final remoteVersion = json['version'] as String? ?? '';
        final apkUrl = json['url'] as String? ?? '';
        if (remoteCode <= currentVersionCode || apkUrl.isEmpty) {
          available.value = null;
          return null;
        }

        final update = AppUpdateInfo(
          version: remoteVersion,
          versionCode: remoteCode,
          apkUrl: apkUrl,
          notes: json['notes'] as String? ?? '',
        );
        available.value = update;
        return update;
      } finally {
        client.close();
      }
    } catch (_) {
      return available.value;
    } finally {
      _checking = false;
    }
  }

  Future<void> downloadAndInstall({
    required void Function(double progress) onProgress,
  }) async {
    if (_installing) return;
    final update = available.value;
    if (update == null) return;
    _installing = true;
    try {
      final file = await _downloadApk(update.apkUrl, onProgress);
      final status = await _channel.invokeMethod<String>('installApk', {
        'path': file.path,
      });
      if (status == 'need_permission') {
        throw const AppUpdatePermissionException();
      }
    } finally {
      _installing = false;
    }
  }

  Future<File> _downloadApk(
    String url,
    void Function(double progress) onProgress,
  ) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/yt-downloader-update.apk');
    if (await file.exists()) {
      await file.delete();
    }

    final client = HttpClient();
    client.userAgent = 'yt-downloader';
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('Download gagal (${response.statusCode})');
      }

      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            onProgress((received / total).clamp(0, 1));
          }
        }
      } finally {
        await sink.close();
      }
      onProgress(1);
      return file;
    } finally {
      client.close();
    }
  }
}

class AppUpdatePermissionException implements Exception {
  const AppUpdatePermissionException();
}
