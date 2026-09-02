import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/clip_campaign.dart';

class ClipCampaignService {
  ClipCampaignService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _ua = 'YT-Downloader/1.0';

  static const curated = <ClipCampaign>[
    ClipCampaign(
      id: 'clipping-board',
      region: CampaignRegion.intl,
      creator: 'Clipping.net',
      marketplace: 'Clipping.net',
      title: 'Browse campaign Clipping.net',
      pay: 'CPM / bounty (cek board)',
      image: 'https://www.google.com/s2/favicons?domain=clipping.net&sz=128',
      postTo: ['TikTok', 'Reels', 'Shorts', 'X'],
      requirements: [
        'Login Clipping.net → buka board clip',
        'Pilih campaign yang masih Active',
        'Pakai source resmi di brief campaign',
      ],
      url: 'https://clipping.net/clip',
      searchQuery: 'clipping campaign',
      clipBrief:
          'Pilih campaign aktif di Clipping.net. Hook di 1–3 detik pertama.',
      source: CampaignSource.curated,
    ),
    ClipCampaign(
      id: 'trybuzzer-board',
      region: CampaignRegion.id,
      creator: 'TryBuzzer',
      marketplace: 'TryBuzzer',
      title: 'Browse bounty TryBuzzer',
      pay: 'tier / CPM (cek board)',
      image: 'https://www.google.com/s2/favicons?domain=trybuzzer.com&sz=128',
      postTo: ['TikTok', 'Instagram', 'Shorts'],
      requirements: [
        'Buka TryBuzzer → Jelajahi kampanye',
        'Pilih bounty yang masih aktif',
        'Download materi resmi dari brief',
      ],
      url: 'https://www.trybuzzer.com/bounty',
      searchQuery: 'TryBuzzer clipping',
      clipBrief: 'Pilih bounty aktif di TryBuzzer. Pakai materi resmi.',
      source: CampaignSource.curated,
    ),
    ClipCampaign(
      id: 'clippo-board',
      region: CampaignRegion.id,
      creator: 'Clippo',
      marketplace: 'Clippo',
      title: 'Browse campaign Clippo',
      pay: 'CPM (cek Clippo)',
      image: 'https://www.google.com/s2/favicons?domain=clippo.id&sz=128',
      postTo: ['TikTok', 'Instagram'],
      requirements: [
        'Daftar clippo.id → pilih campaign aktif',
        'Pakai source resmi campaign',
        'Upload sesuai brief',
      ],
      url: 'https://clippo.id',
      searchQuery: 'Clippo clipping',
      clipBrief: 'Pilih campaign aktif di Clippo.',
      source: CampaignSource.curated,
    ),
  ];

  Future<({List<ClipCampaign> campaigns, String? notice})> fetchCampaigns({
    CampaignRegion? region,
    String query = '',
  }) async {
    final notices = <String>[];
    final konten = await _fetchKonten();
    final vyro = await _fetchVyro();
    if (konten.error != null) notices.add('Konten: ${konten.error}');
    if (vyro.error != null) notices.add('Vyro: ${vyro.error}');

    var list = <ClipCampaign>[...vyro.list, ...konten.list];
    if (list.isEmpty) {
      list = [...curated];
      notices.add('Board live kosong — fallback tautan platform.');
    } else {
      notices.add(
        '${konten.list.length} Konten · ${vyro.list.length} Vyro',
      );
    }

    if (region != null) {
      list = list.where((c) => c.region == region).toList();
    }
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (c) =>
                '${c.title} ${c.creator} ${c.marketplace} ${c.pay}'
                    .toLowerCase()
                    .contains(q),
          )
          .toList();
    }
    list.sort((a, b) {
      final pay = b.paySort.compareTo(a.paySort);
      if (pay != 0) return pay;
      final da = a.deadlineAt ?? 1 << 30;
      final db = b.deadlineAt ?? 1 << 30;
      if (da != db) return da.compareTo(db);
      return a.title.compareTo(b.title);
    });
    return (campaigns: list, notice: notices.join(' · '));
  }

  Future<({List<ClipCampaign> list, String? error})> _fetchKonten() async {
    try {
      final res = await _client.get(
        Uri.parse('https://konten.com/api/campaigns'),
        headers: {'Accept': 'application/json', 'User-Agent': _ua},
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final all = (data['campaigns'] as List?) ?? const [];
      final out = <ClipCampaign>[];
      for (final raw in all) {
        if (raw is! Map) continue;
        final c = Map<String, dynamic>.from(raw);
        if ((c['content_type'] ?? '').toString().toLowerCase() != 'clipping') {
          continue;
        }
        final status = (c['status'] ?? 'active').toString().toLowerCase();
        if (status != 'active' && status != 'paused') continue;
        final slug = c['slug']?.toString() ?? '';
        final title = c['title']?.toString() ?? '';
        if (slug.isEmpty || title.isEmpty) continue;
        final brand = c['brand']?.toString() ?? 'Konten.com';
        final rates = [
          c['rate_per_million'],
          c['cpm_tiktok'],
          c['cpm_youtube'],
        ].whereType<num>().where((n) => n > 0).toList();
        final paySort = rates.isEmpty
            ? 0.0
            : rates.reduce((a, b) => a > b ? a : b) / 16000;
        final pay = rates.isEmpty
            ? 'CPM cek di board'
            : 'Rp ${rates.first.round()} / 1.000 views';
        out.add(
          ClipCampaign(
            id: 'konten:$slug',
            region: CampaignRegion.id,
            creator: brand,
            marketplace: 'Konten.com',
            title: title,
            pay: pay,
            image: c['thumbnail_url']?.toString() ??
                c['brand_logo']?.toString() ??
                'https://www.google.com/s2/favicons?domain=konten.com&sz=128',
            postTo: const ['TikTok', 'Instagram', 'YouTube'],
            requirements: [
              if (c['min_video_duration'] is num)
                'Durasi clip min ~${c['min_video_duration']} detik',
              if (c['brief_instructions'] != null)
                c['brief_instructions'].toString().substring(
                      0,
                      (c['brief_instructions'].toString().length).clamp(0, 120),
                    ),
            ],
            url: 'https://konten.com/campaigns/$slug/brief',
            searchQuery: title,
            clipBrief:
                'Campaign Konten.com: $title (brand $brand). Hook kuat di 1–3 detik.',
            source: CampaignSource.konten,
            sourceVideoUrl: c['source_video_url']?.toString(),
            paySort: paySort,
          ),
        );
      }
      return (list: out, error: null);
    } catch (e) {
      return (list: <ClipCampaign>[], error: e.toString());
    }
  }

  Future<({List<ClipCampaign> list, String? error})> _fetchVyro() async {
    try {
      final res = await _client.get(
        Uri.parse('https://www.vyro.com/api/campaigns'),
        headers: {'Accept': 'application/json', 'User-Agent': _ua},
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final all = (data['data'] as List?) ?? const [];
      final out = <ClipCampaign>[];
      for (final raw in all) {
        if (raw is! Map) continue;
        final c = Map<String, dynamic>.from(raw);
        if ((c['type'] ?? '').toString().toLowerCase() == 'ugc') continue;
        final status = (c['status'] as Map?)?['id']?.toString().toLowerCase();
        if (status != null && status != 'active') continue;
        final slug = c['slug']?.toString() ?? '';
        final title =
            c['name']?.toString() ?? (c['workspace'] as Map?)?['name']?.toString();
        if (slug.isEmpty || title == null || title.isEmpty) continue;
        final creator =
            (c['workspace'] as Map?)?['name']?.toString() ?? title;
        final rate = c['headlineRate'] as num? ??
            (c['payoutModel'] as Map?)?['payRate'] as num?;
        final paySort = rate?.toDouble() ?? 0;
        final pay = rate == null ? 'CPM cek di board' : '\$${rate} / 1.000 views';
        out.add(
          ClipCampaign(
            id: 'vyro:$slug',
            region: CampaignRegion.intl,
            creator: creator,
            marketplace: 'Vyro',
            title: title,
            pay: pay,
            image: (c['workspace'] as Map?)?['image']?.toString() ??
                'https://www.google.com/s2/favicons?domain=vyro.com&sz=128',
            postTo: const ['TikTok', 'Instagram', 'YouTube'],
            requirements: const ['Ikuti brief lengkap di halaman campaign Vyro'],
            url: 'https://www.vyro.com/campaigns/$slug',
            searchQuery: title,
            clipBrief: 'Campaign Vyro: $title ($creator). Hook kuat di 1–3 detik.',
            source: CampaignSource.vyro,
            paySort: paySort,
          ),
        );
      }
      return (list: out, error: null);
    } catch (e) {
      return (list: <ClipCampaign>[], error: e.toString());
    }
  }

  void dispose() => _client.close();
}
