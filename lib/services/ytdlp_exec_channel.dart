import 'dart:convert';

import 'package:flutter/services.dart';

const _playerClients = <String>[
  'youtube:player_client=android,ios,tv',
  'youtube:player_client=ios,tv,mweb',
  'youtube:player_client=tv_embedded,android',
  'youtube:player_client=web,android',
];

/// Raw yt-dlp stdout via Android YoutubeDL.execute (untuk -j / fragment info).
class YtdlpExecChannel {
  YtdlpExecChannel._();
  static final YtdlpExecChannel instance = YtdlpExecChannel._();

  static const _ch = MethodChannel('yt_downloader/ytdlp');

  Future<String> dumpVideoJson({
    required String videoId,
    String? format,
    String? extractorArgs,
  }) async {
    final args = <String, dynamic>{'videoId': videoId};
    if (format != null && format.isNotEmpty) {
      args['format'] = format;
    }
    if (extractorArgs != null && extractorArgs.isNotEmpty) {
      args['extractorArgs'] = extractorArgs;
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
    Object? last;
    for (final client in _playerClients) {
      try {
        final raw = await dumpVideoJson(
          videoId: videoId,
          format: format,
          extractorArgs: client,
        );
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          throw StateError('yt-dlp -j bukan object');
        }
        return decoded;
      } catch (e) {
        last = e;
      }
    }
    throw last ?? StateError('yt-dlp -j gagal');
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
