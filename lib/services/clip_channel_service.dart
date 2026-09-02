import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/clip_campaign.dart';

class ClipChannelService {
  ClipChannelService({YoutubeExplode? yt}) : _yt = yt ?? YoutubeExplode();

  final YoutubeExplode _yt;
  static const _maxChannels = 40;

  Future<File> _storeFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'clip_channels.json'));
  }

  Future<List<SavedClipChannel>> listSaved() async {
    try {
      final file = await _storeFile();
      if (!await file.exists()) return [];
      final parsed = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final list = (parsed['channels'] as List?) ?? const [];
      return [
        for (final raw in list)
          if (raw is Map<String, dynamic>) SavedClipChannel.fromJson(raw),
      ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(List<SavedClipChannel> channels) async {
    final file = await _storeFile();
    await file.writeAsString(
      jsonEncode({
        'channels': [for (final c in channels) c.toJson()],
      }),
    );
  }

  Future<SavedClipChannel> addChannel(String input) async {
    final channel = await resolveChannel(input);
    final list = await listSaved();
    final dup = list.where(
      (c) =>
          (channel.channelId != null && c.channelId == channel.channelId) ||
          c.url.replaceAll(RegExp(r'/+$'), '').toLowerCase() ==
              channel.url.replaceAll(RegExp(r'/+$'), '').toLowerCase(),
    );
    if (dup.isNotEmpty) return dup.first;
    final next = [channel, ...list].take(_maxChannels).toList();
    await _write(next);
    return channel;
  }

  Future<bool> deleteChannel(String id) async {
    final list = await listSaved();
    final next = list.where((c) => c.id != id).toList();
    if (next.length == list.length) return false;
    await _write(next);
    return true;
  }

  Future<SavedClipChannel> resolveChannel(String raw) async {
    final parsed = _normalizeInput(raw);
    if (parsed == null) {
      throw Exception('Tempel @handle, link channel, atau link video YouTube.');
    }

    if (parsed.isVideo) {
      final video = await _yt.videos.get(parsed.url);
      final channel = await _yt.channels.get(video.channelId);
      return SavedClipChannel(
        id: _newId(),
        url: 'https://www.youtube.com/channel/${channel.id.value}/videos',
        title: channel.title,
        handle: channel.url.contains('@') ? '@${channel.url.split('@').last}' : null,
        thumbnail: channel.logoUrl,
        channelId: channel.id.value,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    final channel = await _yt.channels.get(parsed.url);
    return SavedClipChannel(
      id: _newId(),
      url: '${channel.url}/videos',
      title: channel.title,
      handle: channel.url.contains('@') ? '@${channel.url.split('@').last}' : null,
      thumbnail: channel.logoUrl,
      channelId: channel.id.value,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<List<ChannelVideoItem>> listLatestVideos(
    SavedClipChannel channel, {
    int limit = 10,
  }) async {
    final id = channel.channelId;
    if (id == null || id.isEmpty) {
      throw Exception('Channel ID tidak tersedia.');
    }
    final uploads = _yt.channels.getUploads(ChannelId(id));
    final out = <ChannelVideoItem>[];
    await for (final video in uploads) {
      out.add(
        ChannelVideoItem(
          id: video.id.value,
          url: video.url,
          title: video.title,
          channel: video.author,
          durationSec: video.duration?.inSeconds,
          thumbnail: video.thumbnails.mediumResUrl,
          viewCount: null,
        ),
      );
      if (out.length >= limit) break;
    }
    return out;
  }

  String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';

  _ParsedInput? _normalizeInput(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (RegExp(r'^@[\w.-]+$').hasMatch(t)) {
      return _ParsedInput('https://www.youtube.com$t/videos', false);
    }
    var href = t;
    if (!href.startsWith('http') && href.contains('youtube')) {
      href = 'https://$href';
    }
    if (!href.startsWith('http') && RegExp(r'^[\w.-]{2,32}$').hasMatch(t)) {
      return _ParsedInput('https://www.youtube.com/@$t/videos', false);
    }
    Uri? u;
    try {
      u = Uri.parse(href);
    } catch (_) {
      return null;
    }
    final host = u.host.replaceFirst('www.', '').toLowerCase();
    if (host == 'youtu.be') {
      final id = u.pathSegments.isNotEmpty ? u.pathSegments.first : '';
      if (id.isEmpty) return null;
      return _ParsedInput('https://www.youtube.com/watch?v=$id', true);
    }
    if (!host.contains('youtube.com')) return null;
    final v = u.queryParameters['v'];
    if (u.path == '/watch' && v != null) {
      return _ParsedInput('https://www.youtube.com/watch?v=$v', true);
    }
    final shorts = RegExp(r'^/shorts/([\w-]+)').firstMatch(u.path);
    if (shorts != null) {
      return _ParsedInput(
        'https://www.youtube.com/watch?v=${shorts.group(1)}',
        true,
      );
    }
    final ch = RegExp(
      r'^/(@[\w.-]+|channel/[\w-]+|c/[\w.-]+|user/[\w.-]+)',
    ).firstMatch(u.path);
    if (ch != null) {
      return _ParsedInput('https://www.youtube.com${ch.group(0)}/videos', false);
    }
    return null;
  }

  void dispose() => _yt.close();
}

class _ParsedInput {
  const _ParsedInput(this.url, this.isVideo);
  final String url;
  final bool isVideo;
}
