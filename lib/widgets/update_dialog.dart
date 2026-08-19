import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../theme/app_theme.dart';

Future<void> startAppUpdate(BuildContext context) async {
  final update = AppUpdateService.instance.available.value;
  if (update == null) return;

  var progress = 0.0;
  var status = 'Mengunduh APK...';
  var error = '';
  var started = false;
  var closed = false;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setLocal) {
          Future<void> run() async {
            try {
              await AppUpdateService.instance.downloadAndInstall(
                onProgress: (value) {
                  if (closed) return;
                  setLocal(() {
                    progress = value;
                    status = value >= 1
                        ? 'Memasang update...'
                        : 'Mengunduh APK... ${(value * 100).toStringAsFixed(0)}%';
                  });
                },
              );
            } on AppUpdatePermissionException {
              if (closed) return;
              setLocal(() {
                error =
                    'Izinkan YT Downloader memasang aplikasi, lalu tekan Update lagi.';
              });
            } catch (e) {
              if (closed) return;
              setLocal(() => error = 'Gagal update: $e');
            }
          }

          if (!started) {
            started = true;
            WidgetsBinding.instance.addPostFrameCallback((_) => run());
          }

          return AlertDialog(
            title: Text('Update v${update.version}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (update.notes.isNotEmpty) ...[
                  Text(update.notes),
                  const SizedBox(height: 12),
                ],
                if (error.isEmpty) ...[
                  Text(status),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: progress <= 0 ? null : progress,
                    color: AppColors.primary,
                  ),
                ] else
                  Text(error),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  closed = true;
                  Navigator.pop(dialogContext);
                },
                child: Text(error.isEmpty ? 'Sembunyikan' : 'Tutup'),
              ),
            ],
          );
        },
      );
    },
  );
}
