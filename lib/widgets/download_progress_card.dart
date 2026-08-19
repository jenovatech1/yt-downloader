import 'package:flutter/material.dart';

import '../models/download_progress.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';

class DownloadProgressCard extends StatelessWidget {
  const DownloadProgressCard({
    super.key,
    required this.progress,
  });

  final DownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.downloading_rounded, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  progress.phase,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                FormatUtils.percent(progress.progress),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress.progress <= 0 ? null : progress.progress,
              minHeight: 10,
              backgroundColor: AppColors.accent.withValues(alpha: 0.2),
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 14),
          _row(
            'Kecepatan',
            FormatUtils.speedMBps(progress.speedBytesPerSecond),
          ),
          const SizedBox(height: 6),
          _row(
            'Terunduh',
            '${FormatUtils.bytes(progress.downloadedBytes)} / ${FormatUtils.bytes(progress.totalBytes)}',
          ),
          const SizedBox(height: 6),
          _row(
            'Sisa',
            FormatUtils.bytes(progress.remainingBytes),
          ),
          const SizedBox(height: 10),
          Text(
            'Tip: player otomatis pause saat download. Video + audio diunduh paralel.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 13,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}
