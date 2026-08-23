import 'dart:async';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Unduh lewat API youtube_explode (termasuk HLS segment).
/// HLS dari client iOS jauh lebih stabil di Android daripada adaptive progressive.
class YtStreamDownloader {
  static Future<void> download(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    YoutubeExplode? yt,
  }) async {
    Object? lastErr;
    var stream = info;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        if (attempt > 1 && yt != null) {
          stream = await _refresh(yt, info) ?? stream;
        }
        await _viaLibrary(
          yt ?? YoutubeExplode(),
          stream,
          path,
          onBytes: onBytes,
          closeClient: yt == null,
        );
        return;
      } catch (e) {
        lastErr = e;
        try {
          if (await File(path).exists()) await File(path).delete();
        } catch (_) {}
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
    throw Exception('Download gagal setelah retry: $lastErr');
  }

  static Future<void> _viaLibrary(
    YoutubeExplode yt,
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
    required bool closeClient,
  }) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
    final sink = file.openWrite(mode: FileMode.writeOnly);
    final total = info.size.totalBytes;
    var received = 0;
    try {
      await for (final chunk in yt.videos.streamsClient.get(info).timeout(
        const Duration(seconds: 60),
        onTimeout: (s) {
          s.addError(TimeoutException('stall 60s'));
          s.close();
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
      if (closeClient) yt.close();
    }
    if (received < 2048) throw Exception('File terlalu kecil ($received)');
    final isHls = info.container.name.toLowerCase().contains('m3u8') ||
        info.fragments.isNotEmpty;
    final minOk = isHls ? (total * 0.5).round() : (total * 0.85).round();
    if (total > 0 && received < minOk) {
      throw Exception('Download terpotong ($received / $total)');
    }
    final report = total > 0 && received < total ? total : received;
    onBytes(report, total > 0 ? total : received);
  }

  static Future<StreamInfo?> _refresh(YoutubeExplode yt, StreamInfo info) async {
    try {
      final m = await yt.videos.streamsClient.getManifest(
        info.videoId.value,
        ytClients: [
          YoutubeApiClient.ios,
          YoutubeApiClient.androidVr,
          YoutubeApiClient.androidSdkless,
        ],
      );
      for (final s in m.streams) {
        if (s.tag == info.tag) return s;
      }
    } catch (_) {}
    return null;
  }
}
