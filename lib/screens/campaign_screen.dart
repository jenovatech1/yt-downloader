import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/clip_campaign.dart';
import '../services/clip_campaign_service.dart';
import '../services/clip_channel_service.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import 'player_screen.dart';

class CampaignScreen extends StatefulWidget {
  const CampaignScreen({super.key});

  @override
  State<CampaignScreen> createState() => _CampaignScreenState();
}

class _CampaignScreenState extends State<CampaignScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _campaignService = ClipCampaignService();
  final _channelService = ClipChannelService();
  final _youtube = YoutubeService();
  final _searchCtrl = TextEditingController();

  List<ClipCampaign> _campaigns = [];
  List<SavedClipChannel> _channels = [];
  List<ChannelVideoItem> _channelVideos = [];
  SavedClipChannel? _selectedChannel;
  ClipCampaign? _selectedCampaign;
  CampaignRegion? _regionFilter;
  String? _notice;
  bool _loadingCampaigns = true;
  bool _loadingVideos = false;
  bool _addingChannel = false;
  String? _error;
  final _channelInputCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadCampaigns();
    _loadChannels();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    _channelInputCtrl.dispose();
    _campaignService.dispose();
    _channelService.dispose();
    _youtube.dispose();
    super.dispose();
  }

  Future<void> _loadCampaigns() async {
    setState(() {
      _loadingCampaigns = true;
      _error = null;
    });
    try {
      final result = await _campaignService.fetchCampaigns(
        region: _regionFilter,
        query: _searchCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _campaigns = result.campaigns;
        _notice = result.notice;
        _loadingCampaigns = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCampaigns = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadChannels() async {
    final list = await _channelService.listSaved();
    if (!mounted) return;
    setState(() => _channels = list);
  }

  Future<void> _openVideoUrl(String url) async {
    try {
      final video = await _youtube.getVideo(url);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlayerScreen(video: video)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal buka video: ${YoutubeService.shortError(e)}')),
      );
    }
  }

  Future<void> _pickChannel(SavedClipChannel ch) async {
    setState(() {
      _selectedChannel = ch;
      _loadingVideos = true;
      _channelVideos = [];
      _error = null;
    });
    try {
      final videos = await _channelService.listLatestVideos(ch, limit: 10);
      if (!mounted) return;
      setState(() {
        _channelVideos = videos;
        _loadingVideos = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingVideos = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _addChannel() async {
    final input = _channelInputCtrl.text.trim();
    if (input.isEmpty || _addingChannel) return;
    setState(() => _addingChannel = true);
    try {
      final saved = await _channelService.addChannel(input);
      _channelInputCtrl.clear();
      await _loadChannels();
      if (!mounted) return;
      await _pickChannel(saved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _addingChannel = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Campaign & Channel'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Campaign'),
            Tab(text: 'Channel'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildCampaignTab(theme),
          _buildChannelTab(theme),
        ],
      ),
    );
  }

  Widget _buildCampaignTab(ThemeData theme) {
    if (_selectedCampaign != null) {
      final c = _selectedCampaign!;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          IconButton(
            alignment: Alignment.centerLeft,
            onPressed: () => setState(() => _selectedCampaign = null),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          Text(c.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${c.creator} · ${c.marketplace} · ${c.pay}'),
          const SizedBox(height: 12),
          ...c.requirements.map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('• '),
                  Expanded(child: Text(r)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (c.sourceVideoUrl != null && c.sourceVideoUrl!.isNotEmpty)
            FilledButton.icon(
              onPressed: () => _openVideoUrl(c.sourceVideoUrl!),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Buka video sumber'),
            ),
          OutlinedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(c.url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Buka brief campaign'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              final results = await _youtube.search(c.searchQuery);
              if (!mounted || results.isEmpty) return;
              await _openVideoUrl(
                'https://www.youtube.com/watch?v=${results.first.id.value}',
              );
            },
            icon: const Icon(Icons.content_cut_rounded),
            label: const Text('Cari video & Get Clip'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Cari campaign...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: _loadCampaigns,
                icon: const Icon(Icons.refresh_rounded),
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _loadCampaigns(),
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _filterChip('Semua', _regionFilter == null, () {
                setState(() => _regionFilter = null);
                _loadCampaigns();
              }),
              _filterChip('Indonesia', _regionFilter == CampaignRegion.id, () {
                setState(() => _regionFilter = CampaignRegion.id);
                _loadCampaigns();
              }),
              _filterChip('Luar negeri', _regionFilter == CampaignRegion.intl, () {
                setState(() => _regionFilter = CampaignRegion.intl);
                _loadCampaigns();
              }),
            ],
          ),
        ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(_notice!, style: theme.textTheme.bodySmall),
          ),
        Expanded(
          child: _loadingCampaigns
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _campaigns.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final c = _campaigns[i];
                        return ListTile(
                          tileColor: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.35),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: CircleAvatar(
                            backgroundImage: NetworkImage(c.image),
                            onBackgroundImageError: (_, _) {},
                            child: Text(c.title.characters.first),
                          ),
                          title: Text(c.title, maxLines: 2),
                          subtitle: Text('${c.marketplace} · ${c.pay}'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => setState(() => _selectedCampaign = c),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _buildChannelTab(ThemeData theme) {
    if (_selectedChannel != null) {
      final ch = _selectedChannel!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: IconButton(
              onPressed: () => setState(() {
                _selectedChannel = null;
                _channelVideos = [];
              }),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            title: Text(ch.title),
            subtitle: Text(ch.handle ?? ch.url),
          ),
          Expanded(
            child: _loadingVideos
                ? const Center(child: CircularProgressIndicator())
                : _channelVideos.isEmpty
                    ? Center(
                        child: Text(
                          _error ?? 'Tidak ada video.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _channelVideos.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final v = _channelVideos[i];
                          return Card(
                            child: ListTile(
                              leading: v.thumbnail != null
                                  ? Image.network(
                                      v.thumbnail!,
                                      width: 72,
                                      height: 48,
                                      fit: BoxFit.cover,
                                    )
                                  : const Icon(Icons.play_circle_outline),
                              title: Text(v.title, maxLines: 2),
                              subtitle: Text(
                                v.durationSec != null
                                    ? FormatUtils.duration(
                                        Duration(seconds: v.durationSec!),
                                      )
                                    : v.channel,
                              ),
                              onTap: () => _openVideoUrl(v.url),
                            ),
                          );
                        },
                      ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Tambah channel YouTube',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _channelInputCtrl,
                decoration: const InputDecoration(
                  hintText: '@handle atau link channel/video',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _addChannel(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _addingChannel ? null : _addChannel,
              child: _addingChannel
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Channel tersimpan',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (_channels.isEmpty)
          Text(
            'Belum ada channel. Tambahkan @handle untuk lihat 10 video terbaru.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          ..._channels.map(
            (ch) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: ch.thumbnail != null
                    ? CircleAvatar(backgroundImage: NetworkImage(ch.thumbnail!))
                    : CircleAvatar(child: Text(ch.title.characters.first)),
                title: Text(ch.title),
                subtitle: Text(ch.handle ?? 'YouTube'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    await _channelService.deleteChannel(ch.id);
                    await _loadChannels();
                  },
                ),
                onTap: () => _pickChannel(ch),
              ),
            ),
          ),
      ],
    );
  }
}
