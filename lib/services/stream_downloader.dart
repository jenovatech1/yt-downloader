import 'dart:async';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Unduh stream lewat API resmi youtube_explode saja.
///
/// Jangan plain HTTP: YouTube throttle stream; library sudah handle
/// `range` / Range header per-chunk (~10MB). Lihat YoutubeHttpClient._getStream.
class StreamDownloader {
  /// Stall > [stallTimeout] tanpa byte baru → error (jangan hang diam).
  static Future<void> download(
    YoutubeExplode yt,
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    Duration stallTimeout = const Duration(seconds: 25),
  }) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
    final sink = file.openWrite(mode: FileMode.writeOnly);
    final total = info.size.totalBytes;
    var received = 0;

    try {
      await for (final chunk in yt.videos.streamsClient.get(info).timeout(
        stallTimeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException(
              'Download macet (${stallTimeout.inSeconds}s tanpa data). Coba lagi.',
            ),
          );
          sink.close();
        },
      )) {
        if (chunk.isEmpty) continue;
        sink.add(chunk);
        received += chunk.length;
        onBytes(received, total <= 0 ? received : total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (received < 2048) {
      throw Exception('File terlalu kecil ($received byte)');
    }
    if (total > 0 && received < (total * 0.9).round()) {
      throw Exception('Download terpotong ($received / $total byte)');
    }
  }
}
