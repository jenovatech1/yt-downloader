import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/clip_campaign.dart';
import 'clip_channel_service.dart';

class ChannelAlertItem {
  const ChannelAlertItem({
    required this.channelId,
    required this.channelTitle,
    this.channelHandle,
    required this.video,
  });

  final String channelId;
  final String channelTitle;
  final String? channelHandle;
  final ChannelVideoItem video;

  Map<String, dynamic> toJson() => {
        'channelId': channelId,
        'channelTitle': channelTitle,
        if (channelHandle != null) 'channelHandle': channelHandle,
        'video': video.toJson(),
      };

  factory ChannelAlertItem.fromJson(Map<String, dynamic> json) {
    return ChannelAlertItem(
      channelId: json['channelId'] as String? ?? '',
      channelTitle: json['channelTitle'] as String? ?? '',
      channelHandle: json['channelHandle'] as String?,
      video: ChannelVideoItem.fromJson(
        Map<String, dynamic>.from(json['video'] as Map? ?? const {}),
      ),
    );
  }
}

class ChannelAlertCheck {
  const ChannelAlertCheck({
    required this.items,
    required this.checkedAt,
    required this.cached,
  });

  final List<ChannelAlertItem> items;
  final int checkedAt;
  final bool cached;
}

class _WatchEntry {
  const _WatchEntry({
    this.knownVideoIds = const [],
    this.clickedVideoIds = const [],
    this.lastCheckedAt = 0,
  });

  final List<String> knownVideoIds;
  final List<String> clickedVideoIds;
  final int lastCheckedAt;

  _WatchEntry copyWith({
    List<String>? knownVideoIds,
    List<String>? clickedVideoIds,
    int? lastCheckedAt,
  }) {
    return _WatchEntry(
      knownVideoIds: knownVideoIds ?? this.knownVideoIds,
      clickedVideoIds: clickedVideoIds ?? this.clickedVideoIds,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'knownVideoIds': knownVideoIds,
        'clickedVideoIds': clickedVideoIds,
        'lastCheckedAt': lastCheckedAt,
      };

  factory _WatchEntry.fromJson(Map<String, dynamic> json) {
    return _WatchEntry(
      knownVideoIds: [
        for (final id in (json['knownVideoIds'] as List?) ?? const [])
          id.toString(),
      ],
      clickedVideoIds: [
        for (final id in (json['clickedVideoIds'] as List?) ?? const [])
          id.toString(),
      ],
      lastCheckedAt: json['lastCheckedAt'] as int? ?? 0,
    );
  }
}

/// Port desktop `clip-channel-alerts.ts`: popup video baru 24 jam terakhir.
class ClipChannelAlerts {
  static const _dayMs = 24 * 60 * 60 * 1000;
  static const _cooldownMs = 20 * 60 * 1000;
  static const _maxIds = 100;

  Future<File> _storeFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'clip-channel-alerts.json'));
  }

  Future<({Map<String, _WatchEntry> channels, List<ChannelAlertItem> pending})>
      _read() async {
    try {
      final file = await _storeFile();
      if (!await file.exists()) {
        return (channels: <String, _WatchEntry>{}, pending: <ChannelAlertItem>[]);
      }
      final parsed =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final rawCh = parsed['channels'] as Map? ?? const {};
      final channels = <String, _WatchEntry>{};
      for (final e in rawCh.entries) {
        if (e.value is Map) {
          channels[e.key.toString()] = _WatchEntry.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          );
        }
      }
      final pending = [
        for (final raw in (parsed['pending'] as List?) ?? const [])
          if (raw is Map)
            ChannelAlertItem.fromJson(Map<String, dynamic>.from(raw)),
      ];
      return (channels: channels, pending: pending);
    } catch (_) {
      return (channels: <String, _WatchEntry>{}, pending: <ChannelAlertItem>[]);
    }
  }

  Future<void> _write(
    Map<String, _WatchEntry> channels,
    List<ChannelAlertItem> pending,
  ) async {
    final file = await _storeFile();
    await file.writeAsString(
      jsonEncode({
        'channels': {
          for (final e in channels.entries) e.key: e.value.toJson(),
        },
        'pending': [for (final item in pending) item.toJson()],
      }),
    );
  }

  List<String> _uniq(Iterable<String> ids) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      out.add(id);
      if (out.length >= _maxIds) break;
    }
    return out;
  }

  bool _withinLastDay(ChannelVideoItem video, int now) {
    final ts = video.publishedAt;
    if (ts == null || ts <= 0) return true;
    final ms = ts > 1000000000000 ? ts : ts * 1000;
    return now - ms <= _dayMs && ms <= now + 60000;
  }

  List<ChannelAlertItem> _prune(
    List<SavedClipChannel> saved,
    Map<String, _WatchEntry> channels,
    List<ChannelAlertItem> pending,
  ) {
    final ids = {for (final c in saved) c.id};
    return [
      for (final item in pending)
        if (ids.contains(item.channelId) &&
            item.video.id.isNotEmpty &&
            !(channels[item.channelId]?.clickedVideoIds.contains(item.video.id) ??
                false) &&
            !(channels[item.channelId]?.knownVideoIds.contains(item.video.id) ??
                false))
          item,
    ];
  }

  Future<void> seedChannel(
    SavedClipChannel channel, {
    ClipChannelService? service,
  }) async {
    final own = service == null;
    final svc = service ?? ClipChannelService();
    try {
      final store = await _read();
      final channels = Map<String, _WatchEntry>.from(store.channels);
      final entry = channels[channel.id] ?? const _WatchEntry();
      try {
        final videos = await svc.listLatestVideos(channel, limit: 10);
        channels[channel.id] = entry.copyWith(
          knownVideoIds: _uniq([
            ...videos.map((v) => v.id),
            ...entry.knownVideoIds,
          ]),
          lastCheckedAt: DateTime.now().millisecondsSinceEpoch,
        );
      } catch (_) {
        channels[channel.id] = entry.copyWith(
          lastCheckedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
      final saved = await svc.listSaved();
      await _write(channels, _prune(saved, channels, store.pending));
    } finally {
      if (own) svc.dispose();
    }
  }

  Future<void> markClicked(List<String> videoIds, {String? channelId}) async {
    final ids = _uniq(videoIds);
    if (ids.isEmpty) return;
    final svc = ClipChannelService();
    try {
      final saved = await svc.listSaved();
      final store = await _read();
      final channels = Map<String, _WatchEntry>.from(store.channels);
      final targets = channelId != null
          ? [channelId]
          : [for (final c in saved) c.id];
      for (final id in targets) {
        final entry = channels[id] ?? const _WatchEntry();
        channels[id] = entry.copyWith(
          clickedVideoIds: _uniq([...entry.clickedVideoIds, ...ids]),
          knownVideoIds: _uniq([...entry.knownVideoIds, ...ids]),
        );
      }
      await _write(channels, _prune(saved, channels, store.pending));
    } finally {
      svc.dispose();
    }
  }

  Future<void> dismiss([List<String>? videoIds]) async {
    final svc = ClipChannelService();
    try {
      final saved = await svc.listSaved();
      final store = await _read();
      final channels = Map<String, _WatchEntry>.from(store.channels);
      final ids = videoIds != null && videoIds.isNotEmpty
          ? _uniq(videoIds)
          : _uniq(store.pending.map((p) => p.video.id));
      if (ids.isEmpty) {
        await _write(channels, []);
        return;
      }
      for (final ch in saved) {
        final entry = channels[ch.id] ?? const _WatchEntry();
        channels[ch.id] = entry.copyWith(
          knownVideoIds: _uniq([...entry.knownVideoIds, ...ids]),
        );
      }
      await _write(channels, _prune(saved, channels, store.pending));
    } finally {
      svc.dispose();
    }
  }

  Future<void> removeChannel(String channelId) async {
    final store = await _read();
    final channels = Map<String, _WatchEntry>.from(store.channels)
      ..remove(channelId);
    await _write(
      channels,
      [for (final p in store.pending) if (p.channelId != channelId) p],
    );
  }

  Future<ChannelAlertCheck> check({bool force = false}) async {
    final svc = ClipChannelService();
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final saved = await svc.listSaved();
      final store = await _read();
      var channels = Map<String, _WatchEntry>.from(store.channels);
      var pending = _prune(saved, channels, store.pending);

      if (saved.isEmpty) {
        await _write(channels, []);
        return ChannelAlertCheck(items: const [], checkedAt: now, cached: false);
      }

      final needFetch = saved.any((ch) {
        final entry = channels[ch.id] ?? const _WatchEntry();
        return force ||
            entry.lastCheckedAt == 0 ||
            now - entry.lastCheckedAt >= _cooldownMs;
      });

      if (!needFetch) {
        await _write(channels, pending);
        return ChannelAlertCheck(
          items: pending.take(12).toList(),
          checkedAt: now,
          cached: true,
        );
      }

      final found = <ChannelAlertItem>[];
      for (final ch in saved) {
        final entry = channels[ch.id] ?? const _WatchEntry();
        if (!force &&
            entry.lastCheckedAt != 0 &&
            now - entry.lastCheckedAt < _cooldownMs) {
          continue;
        }

        List<ChannelVideoItem> videos;
        try {
          videos = await svc.listLatestVideos(ch, limit: 8);
        } catch (_) {
          channels[ch.id] = entry.copyWith(lastCheckedAt: now);
          continue;
        }

        final known = entry.knownVideoIds.toSet();
        final clicked = entry.clickedVideoIds.toSet();
        if (entry.lastCheckedAt == 0 && known.isEmpty && clicked.isEmpty) {
          channels[ch.id] = _WatchEntry(
            knownVideoIds: _uniq(videos.map((v) => v.id)),
            lastCheckedAt: now,
          );
          continue;
        }

        final newlyKnown = <String>[];
        for (final video in videos) {
          if (known.contains(video.id) || clicked.contains(video.id)) continue;
          if (!_withinLastDay(video, now)) {
            newlyKnown.add(video.id);
            continue;
          }
          found.add(
            ChannelAlertItem(
              channelId: ch.id,
              channelTitle: ch.title,
              channelHandle: ch.handle,
              video: video,
            ),
          );
        }
        channels[ch.id] = entry.copyWith(
          knownVideoIds: _uniq([...entry.knownVideoIds, ...newlyKnown]),
          lastCheckedAt: now,
        );
      }

      final byVideo = <String, ChannelAlertItem>{};
      for (final item in [...pending, ...found]) {
        if (item.video.id.isEmpty) continue;
        byVideo[item.video.id] = item;
      }
      pending = byVideo.values.toList()
        ..sort(
          (a, b) => (b.video.publishedAt ?? 0).compareTo(a.video.publishedAt ?? 0),
        );
      if (pending.length > 12) pending = pending.take(12).toList();
      pending = _prune(saved, channels, pending);
      await _write(channels, pending);
      return ChannelAlertCheck(items: pending, checkedAt: now, cached: false);
    } finally {
      svc.dispose();
    }
  }
}
