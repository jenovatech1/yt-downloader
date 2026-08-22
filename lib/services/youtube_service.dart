import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';
import 'stream_downloader.dart';

class YoutubeService {
  YoutubeService() : _yt = YoutubeExplode();

  final YoutubeExplode _yt;
  final _http = http.Client();

  static const _placeholderChannel = 'UCXXXXXXXXXXXXXXXXXXXXXX';

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

    // Innertube dulu (lebih stabil di Android), fallback ke library.
    try {
      final innertube = await _searchInnertube(trimmed);
      if (innertube.isNotEmpty) return innertube;
    } catch (_) {}

    final results = await _yt.search.search(trimmed);
    return results.take(30).toList();
  }

  Future<List<Video>> _searchInnertube(String query) async {
    final uri = Uri.parse(
      'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
    );
    final response = await _http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
            'Accept-Language': 'en-US,en;q=0.9',
          },
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': 'WEB',
                'clientVersion': '2.20250312.04.00',
                'hl': 'en',
                'gl': 'US',
              },
            },
            'query': query,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Innertube search ${response.statusCode}');
    }
    return _parseInnertubeSearch(response.body);
  }

  List<Video> _parseInnertubeSearch(String body) {
    final root = jsonDecode(body);
    if (root is! Map) return const [];
    final out = <Video>[];
    final seen = <String>{};

    void walk(dynamic node) {
      if (out.length >= 30) return;
      if (node is Map) {
        final renderer = node['videoRenderer'] ?? node['compactVideoRenderer'];
        if (renderer is Map) {
          final id = renderer['videoId']?.toString();
          if (id != null && id.length == 11 && seen.add(id)) {
            final title = _runsText(renderer['title']) ?? 'Video';
            final author = _runsText(renderer['ownerText']) ??
                _runsText(renderer['shortBylineText']) ??
                'YouTube';
            final channelId = _channelIdFrom(renderer) ?? _placeholderChannel;
            final duration = _parseDurationLabel(
              renderer['lengthText'] is Map
                  ? _runsText(renderer['lengthText'])
                  : renderer['lengthText']?.toString(),
            );
            out.add(
              Video(
                VideoId(id),
                title,
                author,
                ChannelId(channelId),
                null,
                null,
                null,
                '',
                duration,
                ThumbnailSet(id),
                const [],
                const Engagement(0, null, null),
                false,
              ),
            );
          }
        }
        for (final value in node.values) {
          walk(value);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(root);
    return out;
  }

  String? _runsText(dynamic node) {
    if (node == null) return null;
    if (node is String) return node.trim().isEmpty ? null : node.trim();
    if (node is! Map) return null;
    final simple = node['simpleText']?.toString();
    if (simple != null && simple.trim().isNotEmpty) return simple.trim();
    final runs = node['runs'];
    if (runs is List) {
      final text = runs
          .map((e) => e is Map ? (e['text']?.toString() ?? '') : '')
          .join()
          .trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  String? _channelIdFrom(Map renderer) {
    for (final candidate in [
      renderer['ownerText'],
      renderer['shortBylineText'],
      renderer['longBylineText'],
    ]) {
      final found = _findChannelId(candidate);
      if (found != null) return found;
    }
    return null;
  }

  String? _findChannelId(dynamic node) {
    if (node is Map) {
      final browse = node['browseId']?.toString();
      if (browse != null && ChannelId.validateChannelId(browse)) return browse;
      for (final value in node.values) {
        final found = _findChannelId(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final item in node) {
        final found = _findChannelId(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  Duration? _parseDurationLabel(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parts = raw.trim().split(':');
    if (parts.any((p) => int.tryParse(p) == null)) return null;
    final nums = parts.map(int.parse).toList();
    if (nums.length == 3) {
      return Duration(hours: nums[0], minutes: nums[1], seconds: nums[2]);
    }
    if (nums.length == 2) {
      return Duration(minutes: nums[0], seconds: nums[1]);
    }
    if (nums.length == 1) return Duration(seconds: nums[0]);
    return null;
  }

  Future<Video> getVideo(String idOrUrl) {
    return _yt.videos.get(idOrUrl);
  }

  YoutubeExplode get client => _yt;

  /// Manifest: default = androidSdkless (paling kompatibel per docs library).
  Future<StreamManifest> getManifest(String videoId) async {
    Object? lastError;

    try {
      final m = await _yt.videos.streamsClient.getManifest(videoId);
      if (m.audioOnly.isNotEmpty ||
          m.videoOnly.isNotEmpty ||
          m.muxed.isNotEmpty) {
        return m;
      }
    } catch (e) {
      lastError = e;
    }

    // Fallback berurutan — library skip client yang gagal lalu merge.
    try {
      return await _yt.videos.streamsClient.getManifest(
        videoId,
        ytClients: [
          YoutubeApiClient.androidSdkless,
          YoutubeApiClient.ios,
          YoutubeApiClient.android,
        ],
      );
    } catch (e) {
      lastError = e;
    }

    throw lastError ?? Exception('Stream tidak tersedia untuk video ini.');
  }

  /// Ambil ulang opsi download dengan URL fresh untuk [height].
  Future<DownloadOption?> resolveDownloadOption(String videoId, int height) async {
    final options = await getDownloadOptions(videoId);
    DownloadOption? exact;
    DownloadOption? muxedFallback;
    for (final o in options) {
      if (o.height == height) {
        if (o.isMuxed) return o;
        exact ??= o;
      }
      if (o.isMuxed) muxedFallback ??= o;
    }
    return exact ?? muxedFallback ?? (options.isEmpty ? null : options.first);
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

  AudioOnlyStreamInfo? compactAudio(StreamManifest manifest) {
    final m4a = manifest.audioOnly.where((s) {
      final n = s.container.name.toLowerCase();
      return n.contains('mp4') || n.contains('m4a');
    }).toList()
      ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    if (m4a.isNotEmpty) return m4a.first;
    final rest = manifest.audioOnly.toList()
      ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    return rest.isEmpty ? null : rest.first;
  }

  VideoOnlyStreamInfo? videoOnlyAt(StreamManifest manifest, int height) =>
      _bestVideoOnlyAt(manifest, height);

  MuxedStreamInfo? muxedAt(StreamManifest manifest, int height) =>
      _bestMuxedAt(manifest, height);

  /// Dipakai Get Clip — hanya via library get() (bukan HTTP plain).
  Future<void> downloadToFile(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
  }) {
    return StreamDownloader.download(
      _yt,
      info,
      path,
      onBytes: onBytes,
    );
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

  int _containerScore(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('mp4') || lower.contains('m4a')) return 2;
    if (lower.contains('webm')) return 1;
    return 0;
  }

  void dispose() {
    _yt.close();
    _http.close();
  }

  static String shortError(Object e) {
    final s = e.toString();
    if (s.contains('fatal failure') ||
        s.contains('FatalFailure') ||
        s.contains('YouTube most likely changed')) {
      return 'YouTube memblokir request. Coba lagi / update app.';
    }
    if (s.length > 180) return '${s.substring(0, 180)}…';
    return s;
  }
}
