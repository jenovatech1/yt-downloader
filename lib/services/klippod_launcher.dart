import 'package:flutter/services.dart';

import '../config/klippod_config.dart';

enum KlippodOpenResult {
  opened,
  notInstalled,
  fileMissing,
  failed,
}

class KlippodOpenOutcome {
  const KlippodOpenOutcome(this.result, {this.message});

  final KlippodOpenResult result;
  final String? message;
}

class KlippodLauncher {
  static const _channel = MethodChannel('yt_downloader/klippod');

  Future<bool> isInstalled() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'isKlippodInstalled',
        {'packageName': KlippodConfig.packageName},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openPlayStore() async {
    await _channel.invokeMethod<void>(
      'openPlayStore',
      {'packageName': KlippodConfig.packageName},
    );
  }

  Future<KlippodOpenOutcome> openClips({
    required List<String> filePaths,
    required String title,
    required String youtubeUrl,
    required String hooksJson,
  }) async {
    try {
      final installed = await isInstalled();
      if (!installed) {
        return const KlippodOpenOutcome(KlippodOpenResult.notInstalled);
      }

      final mode = await _channel.invokeMethod<String>(
        'openClipsInKlippod',
        {
          'paths': filePaths,
          'packageName': KlippodConfig.packageName,
          'title': title,
          'youtubeUrl': youtubeUrl,
          'hooksJson': hooksJson,
        },
      );

      if (mode == 'not_installed') {
        return const KlippodOpenOutcome(KlippodOpenResult.notInstalled);
      }
      return const KlippodOpenOutcome(KlippodOpenResult.opened);
    } on PlatformException catch (e) {
      return KlippodOpenOutcome(
        KlippodOpenResult.failed,
        message: e.message ?? e.code,
      );
    } catch (e) {
      return KlippodOpenOutcome(KlippodOpenResult.failed, message: '$e');
    }
  }

  Future<KlippodOpenOutcome> openVideo({
    required String filePath,
    required String title,
  }) async {
    try {
      final installed = await isInstalled();
      if (!installed) {
        return const KlippodOpenOutcome(KlippodOpenResult.notInstalled);
      }

      final mode = await _channel.invokeMethod<String>(
        'openInKlippod',
        {
          'path': filePath,
          'packageName': KlippodConfig.packageName,
          'title': title,
        },
      );

      if (mode == 'not_installed') {
        return const KlippodOpenOutcome(KlippodOpenResult.notInstalled);
      }
      return const KlippodOpenOutcome(KlippodOpenResult.opened);
    } on PlatformException catch (e) {
      final msg = e.message ?? e.code;
      if (msg.contains('tidak ditemukan') || msg.contains('File tidak')) {
        return KlippodOpenOutcome(KlippodOpenResult.fileMissing, message: msg);
      }
      return KlippodOpenOutcome(KlippodOpenResult.failed, message: msg);
    } catch (e) {
      return KlippodOpenOutcome(KlippodOpenResult.failed, message: '$e');
    }
  }
}
