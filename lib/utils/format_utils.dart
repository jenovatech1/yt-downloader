class FormatUtils {
  static String bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Transfer speed in MB/s (megabytes per second).
  static String speedMBps(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0.0 MB/s';
    final mbps = bytesPerSecond / (1024 * 1024);
    if (mbps < 0.1) {
      final kbps = bytesPerSecond / 1024;
      return '${kbps.toStringAsFixed(0)} KB/s';
    }
    return '${mbps.toStringAsFixed(1)} MB/s';
  }

  static String duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String percent(double value) {
    return '${(value * 100).clamp(0, 100).toStringAsFixed(0)}%';
  }
}
