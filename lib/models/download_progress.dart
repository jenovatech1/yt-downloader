class DownloadProgress {
  const DownloadProgress({
    required this.phase,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speedBytesPerSecond,
    this.isDone = false,
    this.error,
  });

  final String phase;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSecond;
  final bool isDone;
  final String? error;

  int get remainingBytes => (totalBytes - downloadedBytes).clamp(0, totalBytes);

  factory DownloadProgress.fromMap(Map<String, dynamic> map) {
    return DownloadProgress(
      phase: map['phase'] as String? ?? '',
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
      downloadedBytes: map['downloadedBytes'] as int? ?? 0,
      totalBytes: map['totalBytes'] as int? ?? 0,
      speedBytesPerSecond:
          (map['speedBytesPerSecond'] as num?)?.toDouble() ?? 0,
      isDone: map['isDone'] as bool? ?? false,
      error: map['error'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'phase': phase,
        'progress': progress,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'speedBytesPerSecond': speedBytesPerSecond,
        'isDone': isDone,
        'error': error,
      };

  static const idle = DownloadProgress(
    phase: '',
    progress: 0,
    downloadedBytes: 0,
    totalBytes: 0,
    speedBytesPerSecond: 0,
  );
}
