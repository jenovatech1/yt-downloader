import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_option.dart';

class YoutubeService {
  YoutubeService() : _yt = YoutubeExplode();

  YoutubeExplode _yt;
  final _http = http.Client();

  static const _placeholderChannel = 'UCXXXXXXXXXXXXXXXXXXXXXX';

  void _resetClient() {
    try {
      _yt.close();
    } catch (_) {}
    _yt = YoutubeExplode();
  }

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
      return [await getVideo(videoId)];
    }

    Object? lastError;

    // Innertube dulu — di Android HTML scrape sering 400/fatal.
    try {
      final innertube = await _searchInnertube(trimmed);
      if (innertube.isNotEmpty) return innertube;
    } catch (e) {
      lastError = e;
    }

    try {
      final results = await _yt.search.search(trimmed).timeout(
            const Duration(seconds: 20),
          );
      final list = results.take(30).toList();
      if (list.isNotEmpty) return list;
    } catch (e) {
      lastError = e;
      _resetClient();
    }

    throw lastError ?? Exception('Tidak ada hasil pencarian.');
  }

  Future<List<Video>> _searchInnertube(String query) async {
    final attempts = [
      {
        'clientName': 'WEB',
        'clientVersion': '2.20250312.04.00',
        'userAgent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      },
      {
        'clientName': 'ANDROID',
        'clientVersion': '20.10.38',
        'userAgent':
            'com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip',
      },
    ];

    Object? lastError;
    for (final client in attempts) {
      try {
        final uri = Uri.parse(
          'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
        );
        final response = await _http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': client['userAgent']!,
                'Accept-Language': 'en-US,en;q=0.9',
              },
              body: jsonEncode({
                'context': {
                  'client': {
                    'clientName': client['clientName'],
                    'clientVersion': client['clientVersion'],
                    'hl': 'en',
                    'gl': 'US',
                  },
                },
                'query': query,
              }),
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception(
            'Innertube search ${response.statusCode}',
          );
        }

        final videos = _parseInnertubeSearch(response.body);
        if (videos.isNotEmpty) return videos;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('Innertube search kosong');
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
            final title = _runsText(renderer['title']) ??
                _runsText(renderer['headline']) ??
                'Video';
            final author = _runsText(renderer['ownerText']) ??
                _runsText(renderer['shortBylineText']) ??
                _runsText(renderer['longBylineText']) ??
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
    final candidates = <dynamic>[
      renderer['ownerText'],
      renderer['shortBylineText'],
      renderer['longBylineText'],
      renderer['channelThumbnailSupportedRenderers'],
    ];
    for (final candidate in candidates) {
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
    if (nums.length == 1) {
      return Duration(seconds: nums[0]);
    }
    return null;
  }

  Future<Video> getVideo(String idOrUrl) async {
    try {
      return await _yt.videos.get(idOrUrl).timeout(const Duration(seconds: 20));
    } catch (_) {
      _resetClient();
      final id = tryParseVideoId(idOrUrl) ?? idOrUrl;
      // Fallback ringan kalau watch page gagal — cukup buat buka player.
      return Video(
        VideoId(id),
        'YouTube video',
        'YouTube',
        ChannelId(_placeholderChannel),
        null,
        null,
        null,
        '',
        null,
        ThumbnailSet(id),
        const [],
        const Engagement(0, null, null),
        false,
      );
    }
  }

  Future<StreamManifest> getManifest(String videoId) async {
    // ANDROID (sdkVersion) = 403 fatal. androidSdkless sering hang di HEAD.
    // androidVr dulu yang bikin Download jalan.
    final attempts = <List<YoutubeApiClient>>[
      [YoutubeApiClient.androidVr],
      [YoutubeApiClient.ios],
      [YoutubeApiClient.tv],
      [YoutubeApiClient.safari],
    ];
    Object? lastError;
    for (final clients in attempts) {
      try {
        return await _yt.videos.streamsClient
            .getManifest(videoId, ytClients: clients)
            .timeout(const Duration(seconds: 12));
      } catch (e) {
        lastError = e;
        _resetClient();
      }
    }
    throw lastError ??
        Exception('Tidak ada stream YouTube yang bisa dipakai.');
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

  /// Audio kecil untuk transkrip (lebih cepat, lolos limit Groq).
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

  Future<void> downloadToFile(
    StreamInfo info,
    String path, {
    required void Function(int received, int total) onBytes,
  }) async {
    final file = File(path);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    final total = info.size.totalBytes;
    var received = 0;
    StreamIterator<List<int>>? iterator;
    try {
      final stream = _yt.videos.streamsClient.get(info);
      iterator = StreamIterator(stream);
      final hasFirst = await iterator.moveNext().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException(
          'YouTube tidak mengirim data (timeout 12s)',
        ),
      );
      if (!hasFirst) {
        throw Exception('Stream audio kosong');
      }
      sink.add(iterator.current);
      received += iterator.current.length;
      onBytes(received, total <= 0 ? received : total);

      while (await iterator.moveNext()) {
        sink.add(iterator.current);
        received += iterator.current.length;
        onBytes(received, total <= 0 ? received : total);
      }
      await sink.flush();
      if (received < 2048) {
        throw Exception('File audio terlalu kecil ($received byte)');
      }
    } catch (e) {
      _resetClient();
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    } finally {
      try {
        await iterator?.cancel();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }
  }

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
    try {
      _yt.close();
    } catch (_) {}
    _http.close();
  }

  static String shortError(Object e) {
    final s = e.toString();
    if (s.contains('fatal failure') ||
        s.contains('FatalFailure') ||
        s.contains('YouTube most likely changed')) {
      return 'YouTube memblokir request. Coba link video langsung, atau update app.';
    }
    if (s.length > 180) return '${s.substring(0, 180)}…';
    return s;
  }
}
