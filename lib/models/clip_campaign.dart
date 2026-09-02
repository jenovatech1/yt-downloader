enum CampaignRegion { id, intl }

enum CampaignSource { konten, vyro, contentrewards, curated, mychannel }

class ClipCampaign {
  const ClipCampaign({
    required this.id,
    required this.region,
    required this.creator,
    required this.marketplace,
    required this.title,
    required this.pay,
    required this.image,
    required this.postTo,
    required this.requirements,
    required this.url,
    required this.searchQuery,
    required this.clipBrief,
    this.source = CampaignSource.curated,
    this.sourceVideoUrl,
    this.paySort = 0,
    this.deadlineAt,
  });

  final String id;
  final CampaignRegion region;
  final String creator;
  final String marketplace;
  final String title;
  final String pay;
  final String image;
  final List<String> postTo;
  final List<String> requirements;
  final String url;
  final String searchQuery;
  final String clipBrief;
  final CampaignSource source;
  final String? sourceVideoUrl;
  final double paySort;
  final int? deadlineAt;
}

class SavedClipChannel {
  const SavedClipChannel({
    required this.id,
    required this.url,
    required this.title,
    this.handle,
    this.thumbnail,
    this.channelId,
    required this.addedAt,
  });

  final String id;
  final String url;
  final String title;
  final String? handle;
  final String? thumbnail;
  final String? channelId;
  final int addedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        if (handle != null) 'handle': handle,
        if (thumbnail != null) 'thumbnail': thumbnail,
        if (channelId != null) 'channelId': channelId,
        'addedAt': addedAt,
      };

  factory SavedClipChannel.fromJson(Map<String, dynamic> json) {
    return SavedClipChannel(
      id: json['id'] as String,
      url: json['url'] as String,
      title: json['title'] as String? ?? 'YouTube',
      handle: json['handle'] as String?,
      thumbnail: json['thumbnail'] as String?,
      channelId: json['channelId'] as String?,
      addedAt: json['addedAt'] as int? ?? 0,
    );
  }
}

class ChannelVideoItem {
  const ChannelVideoItem({
    required this.id,
    required this.url,
    required this.title,
    required this.channel,
    this.durationSec,
    this.thumbnail,
    this.viewCount,
  });

  final String id;
  final String url;
  final String title;
  final String channel;
  final int? durationSec;
  final String? thumbnail;
  final int? viewCount;
}

String buildCampaignClipBrief(ClipCampaign campaign) {
  final reqs = campaign.requirements
      .take(4)
      .toList()
      .asMap()
      .entries
      .map((e) => '${e.key + 1}) ${e.value}')
      .join(' ');
  return '${campaign.clipBrief}\n'
      'Syarat (${campaign.marketplace} · ${campaign.title}): $reqs';
}
