import 'dart:convert';

import 'package:flutter/services.dart';

/// Raw yt-dlp stdout via Android YoutubeDL.execute (untuk -j / fragment info).
class YtdlpExecChannel {
  YtdlpExecChannel._();
  static final YtdlpExecChannel instance = YtdlpExecChannel._();

  static const _ch = MethodChannel('yt_downloader/ytdlp');

  Future<String> dumpVideoJson({
    required String videoId,
    String? format,
  }) async {
    final args = <String, dynamic>{'videoId': videoId};
    if (format != null && format.isNotEmpty) {
      args['format'] = format;
    }
    final out = await _ch.invokeMethod<String>('dumpVideoJson', args);
    if (out == null || out.trim().isEmpty) {
      throw StateError('yt-dlp -j kosong');
    }
    return out;
  }

  Future<Map<String, dynamic>> dumpVideoJsonMap({
    required String videoId,
    String? format,
  }) async {
    final raw = await dumpVideoJson(videoId: videoId, format: format);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('yt-dlp -j bukan object');
    }
    return decoded;
  }

  Future<String> muxLocalClip({
    required String videoPath,
    String? audioPath,
    required String outputPath,
    required double videoTrimStartSec,
    double? audioTrimStartSec,
    required double durationSec,
  }) async {
    final out = await _ch.invokeMethod<String>('muxLocalClip', {
      'videoPath': videoPath,
      'audioPath': audioPath,
      'outputPath': outputPath,
      'videoTrimStartSec': videoTrimStartSec,
      'audioTrimStartSec': audioTrimStartSec ?? videoTrimStartSec,
      'durationSec': durationSec,
    });
    if (out == null || out.isEmpty) {
      throw StateError('FFmpeg tidak menghasilkan klip');
    }
    return out;
  }
}
