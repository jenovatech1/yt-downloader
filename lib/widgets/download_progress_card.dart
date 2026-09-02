import 'dart:async';

import 'package:flutter/material.dart';

import '../models/download_progress.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';

class DownloadProgressCard extends StatefulWidget {
  const DownloadProgressCard({
    super.key,
    required this.progress,
    this.tip,
  });

  final DownloadProgress progress;
  final String? tip;

  @override
  State<DownloadProgressCard> createState() => _DownloadProgressCardState();
}

class _DownloadProgressCardState extends State<DownloadProgressCard> {
  DateTime? _startedAt;
  Timer? _tick;

  @override
  void didUpdateWidget(DownloadProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer(oldWidget.progress);
  }

  @override
  void initState() {
    super.initState();
    _syncTimer(null);
  }

  void _syncTimer(DownloadProgress? old) {
    final active = widget.progress.phase.isNotEmpty && !widget.progress.isDone;
    if (active) {
      final restarted = old != null &&
          old.progress > 0.85 &&
          widget.progress.progress < 0.08;
      if (_startedAt == null || restarted) {
        _startedAt = DateTime.now();
      }
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
      if (widget.progress.phase.isEmpty) _startedAt = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Duration get _elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  Duration? get _eta {
    final speed = widget.progress.speedBytesPerSecond;
    final rem = widget.progress.remainingBytes;
    if (speed <= 0 || rem <= 0) return null;
    return Duration(seconds: (rem / speed).round());
  }

  double? _barValue(DownloadProgress progress, bool hasBytes) {
    if (progress.progress <= 0) return null;
    // Transkrip / AI belum ada byte — bar indeterminate biar kelihatan jalan.
    if (!hasBytes && progress.progress < 0.52) return null;
    return progress.progress;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = widget.progress;
    final hasBytes = progress.downloadedBytes > 0 || progress.totalBytes > 0;
    final hasSpeed = progress.speedBytesPerSecond > 0;
    final elapsedLabel = FormatUtils.duration(_elapsed);
    final eta = _eta;

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
                '${FormatUtils.percent(progress.progress)} · $elapsedLabel',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (progress.detail != null && progress.detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              progress.detail!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _barValue(progress, hasBytes),
              minHeight: 10,
              backgroundColor: AppColors.accent.withValues(alpha: 0.2),
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 14),
          if (eta != null) ...[
            _row('Estimasi sisa', FormatUtils.duration(eta)),
            const SizedBox(height: 6),
          ],
          _row(
            'Kecepatan',
            hasSpeed
                ? FormatUtils.speedMBps(progress.speedBytesPerSecond)
                : '—',
          ),
          const SizedBox(height: 6),
          _row(
            'Terunduh',
            hasBytes
                ? '${FormatUtils.bytes(progress.downloadedBytes)} / '
                    '${FormatUtils.bytes(progress.displayTotalBytes)}'
                : (progress.detail != null &&
                        progress.detail!.contains('belum unduh'))
                    ? 'Menyiapkan… (belum unduh klip)'
                    : 'Menunggu data unduhan…',
          ),
          if (hasBytes) ...[
            const SizedBox(height: 6),
            _row(
              'Sisa',
              FormatUtils.bytes(progress.remainingBytes),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            widget.tip ??
                'Tip: unduhan via yt-dlp. Progress dari log unduhan (MB / kecepatan).',
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
