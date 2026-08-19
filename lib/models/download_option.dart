import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class DownloadOption {
  const DownloadOption({
    required this.label,
    required this.height,
    required this.totalBytes,
    required this.isMuxed,
    this.muxed,
    this.videoOnly,
    this.audioOnly,
  });

  final String label;
  final int height;
  final int totalBytes;
  final bool isMuxed;
  final MuxedStreamInfo? muxed;
  final VideoOnlyStreamInfo? videoOnly;
  final AudioOnlyStreamInfo? audioOnly;

  String get sizeLabel {
    final mb = totalBytes / (1024 * 1024);
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }
}
