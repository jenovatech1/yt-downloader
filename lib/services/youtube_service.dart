import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';

class YoutubeService {
  YoutubeService() : _yt = YoutubeExplode();

  final YoutubeExplode _yt;

  bool looksLikeUrl(String input) {
    final trimmed = input.trim();
    final value = trimmed.toLowerCase();
    if (value.contains('youtube.com') ||
        value.contains('youtu.be') ||
        value.contains('music.youtube.com')) {
      return true;
    }
    return RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(trimmed);
  }

  String? tryParseVideoId(String input) {
    try {
      return VideoId(input.trim()).value;
    } catch (_) {
      return VideoId.parseVideoId(input.trim());
    }
  }

  Future<List<Video>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final videoId = tryParseVideoId(trimmed);
    if (videoId != null) {
      final video = await _yt.videos.get(videoId);
      return [video];
    }

    final results = await _yt.search.search(trimmed);
    return results.take(30).toList();
  }

  Future<Video> getVideo(String idOrUrl) {
    return _yt.videos.get(idOrUrl);
  }

  Future<StreamManifest> getManifest(String videoId) {
    return _yt.videos.streamsClient.getManifest(
      videoId,
      ytClients: [
        YoutubeApiClient.androidVr,
        YoutubeApiClient.android,
        YoutubeApiClient.tv,
      ],
    );
  }

  Future<String?> getPlayableUrl(String videoId) async {
    final manifest = await getManifest(videoId);

    final muxed = manifest.muxed
        .where((s) => s.videoResolution.height <= 1080)
        .toList()
      ..sort(
        (a, b) =>
            b.videoResolution.height.compareTo(a.videoResolution.height),
      );
    if (muxed.isNotEmpty) {
      return muxed.first.url.toString();
    }

    final hls = manifest.hls.whereType<HlsMuxedStreamInfo>().toList();
    if (hls.isNotEmpty) {
      hls.sort(
        (a, b) =>
            b.videoResolution.height.compareTo(a.videoResolution.height),
      );
      return hls.first.url.toString();
    }

    return null;
  }

  Future<List<DownloadOption>> getDownloadOptions(String videoId) async {
    final manifest = await getManifest(videoId);
    final audio = _bestAudio(manifest);
    final options = <DownloadOption>[];
    final usedHeights = <int>{};

    // Semua resolusi unik dari muxed + video-only.
    final heights = <int>{
      ...manifest.muxed.map((s) => s.videoResolution.height),
      ...manifest.videoOnly.map((s) => s.videoResolution.height),
    }.where((h) => h > 0).toList()
      ..sort((a, b) => b.compareTo(a));

    for (final height in heights) {
      if (usedHeights.contains(height)) continue;

      final muxed = _bestMuxedAt(manifest, height);
      if (muxed != null) {
        usedHeights.add(height);
        options.add(
          DownloadOption(
            label: _qualityLabel(muxed.qualityLabel, height),
            height: height,
            totalBytes: muxed.size.totalBytes,
            isMuxed: true,
            muxed: muxed,
          ),
        );
        continue;
      }

      final videoOnly = _bestVideoOnlyAt(manifest, height);
      if (videoOnly != null && audio != null) {
        usedHeights.add(height);
        options.add(
          DownloadOption(
            label: _qualityLabel(videoOnly.qualityLabel, height),
            height: height,
            totalBytes: videoOnly.size.totalBytes + audio.size.totalBytes,
            isMuxed: false,
            videoOnly: videoOnly,
            audioOnly: audio,
          ),
        );
      }
    }

    options.sort((a, b) => b.height.compareTo(a.height));
    return options;
  }

  String _qualityLabel(String raw, int height) {
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return '${height}p';
    // Contoh: "1080p60" / "720p" — pakai label YouTube kalau ada.
    return cleaned.contains('p') ? cleaned : '${height}p';
  }

  Stream<List<int>> openStream(StreamInfo streamInfo) {
    return _yt.videos.streamsClient.get(streamInfo);
  }

  MuxedStreamInfo? _bestMuxedAt(StreamManifest manifest, int height) {
    final candidates = manifest.muxed
        .where((s) => s.videoResolution.height == height)
        .toList()
      ..sort((a, b) {
        final containerScore =
            _containerScore(b.container.name) - _containerScore(a.container.name);
        if (containerScore != 0) return containerScore;
        return b.bitrate.compareTo(a.bitrate);
      });
    return candidates.isEmpty ? null : candidates.first;
  }

  VideoOnlyStreamInfo? _bestVideoOnlyAt(StreamManifest manifest, int height) {
    final candidates = manifest.videoOnly
        .where((s) => s.videoResolution.height == height)
        .toList()
      ..sort((a, b) {
        final containerScore =
            _containerScore(b.container.name) - _containerScore(a.container.name);
        if (containerScore != 0) return containerScore;
        return b.bitrate.compareTo(a.bitrate);
      });
    return candidates.isEmpty ? null : candidates.first;
  }

  AudioOnlyStreamInfo? bestAudio(StreamManifest manifest) =>
      _bestAudio(manifest);

  /// Stream video ringan untuk potongan hook (utamakan mp4 ≤720p).
  VideoOnlyStreamInfo? bestClipVideo(StreamManifest manifest) {
    const preferred = [720, 480, 360, 540, 1080];
    for (final height in preferred) {
      final match = _bestVideoOnlyAt(manifest, height);
      if (match != null) return match;
    }
    final rest = manifest.videoOnly.toList()
      ..sort((a, b) {
        final byHeight =
            a.videoResolution.height.compareTo(b.videoResolution.height);
        if (byHeight != 0) return byHeight;
        return _containerScore(b.container.name) -
            _containerScore(a.container.name);
      });
    return rest.isEmpty ? null : rest.first;
  }

  AudioOnlyStreamInfo? _bestAudio(StreamManifest manifest) {
    final candidates = manifest.audioOnly.toList()
      ..sort((a, b) {
        final containerScore =
            _containerScore(b.container.name) - _containerScore(a.container.name);
        if (containerScore != 0) return containerScore;
        return b.bitrate.compareTo(a.bitrate);
      });
    return candidates.isEmpty ? null : candidates.first;
  }

  // Prefer mp4/m4a so the minimal FFmpeg build can mux with stream copy.
  int _containerScore(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('mp4') || lower.contains('m4a')) return 2;
    if (lower.contains('webm')) return 1;
    return 0;
  }

  void dispose() {
    _yt.close();
  }
}
