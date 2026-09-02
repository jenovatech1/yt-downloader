import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/own_ai_clip.dart';
import '../theme/app_theme.dart';

/// Clipboard Android sering memotong teks panjang (~20k+ karakter).
const _kClipboardWarnChars = 18000;

class OwnAiClipPanel extends StatefulWidget {
  const OwnAiClipPanel({
    super.key,
    required this.exportText,
    required this.exportFileName,
    required this.onApply,
    this.applying = false,
    this.initialPaste = '',
  });

  final String? exportText;
  final String exportFileName;
  final ValueChanged<String> onApply;
  final bool applying;
  final String initialPaste;

  @override
  State<OwnAiClipPanel> createState() => _OwnAiClipPanelState();
}

class _OwnAiClipPanelState extends State<OwnAiClipPanel> {
  late final TextEditingController _pasteCtrl;
  bool _copied = false;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _pasteCtrl = TextEditingController(text: widget.initialPaste);
  }

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  bool get _exportReady => widget.exportText?.trim().isNotEmpty == true;

  OwnAiParseResult get _preview => parseOwnAiClipPaste(_pasteCtrl.text);

  Future<void> _copyExport() async {
    final text = widget.exportText;
    if (text == null || text.isEmpty) return;

    if (text.length > _kClipboardWarnChars && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Transkrip panjang'),
          content: Text(
            'Copy mungkin tidak lengkap di chat (${text.length} karakter). '
            'Lebih aman pakai Download file.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Copy tetap'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _downloadExport() async {
    final text = widget.exportText;
    if (text == null || text.isEmpty || _downloading) return;
    setState(() => _downloading = true);
    try {
      final safeName = widget.exportFileName.trim().isNotEmpty
          ? widget.exportFileName
          : 'transkrip_clip.txt';
      const channel = MethodChannel('yt_downloader/files');
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'savePublicText',
        {'fileName': safeName, 'content': text},
      );
      final location = raw?['location']?.toString() ?? 'Documents/YT Downloader';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Tersimpan di $location — di AI pilih file → Recent / Documents',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      // Fallback: Downloads publik kalau MediaStore gagal.
      try {
        final dir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        final exports = Directory(p.join(dir.path, 'YT Downloader'));
        await exports.create(recursive: true);
        final safeName = widget.exportFileName.trim().isNotEmpty
            ? widget.exportFileName
            : 'transkrip_clip.txt';
        final file = File(p.join(exports.path, safeName));
        await file.writeAsString(text);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Tersimpan di Download/YT Downloader/${file.uri.pathSegments.last}'),
            duration: const Duration(seconds: 4),
          ),
        );
      } catch (e2) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal simpan file: $e2')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;
    final canApply = preview.ok && !widget.applying;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _exportReady
            ? AppColors.primary.withValues(alpha: 0.06)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _exportReady
              ? AppColors.primary.withValues(alpha: 0.28)
              : theme.dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Clip dengan AI sendiri',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Kami transcribe. ChatGPT / Claude / Gemini kamu pilih momen.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _exportReady
                      ? AppColors.primary.withValues(alpha: 0.12)
                      : theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _exportReady ? 'Transkrip siap' : 'Menunggu transcribe',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _exportReady
                        ? AppColors.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _stepChip('1. Transcribe', 'Groq/Gemini Whisper'),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _stepChip('2. Kirim ke AI', 'Copy / download file'),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _stepChip('3. Paste balasan', 'JSON di bawah'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _exportReady ? _copyExport : null,
                icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
                label: Text(_copied ? 'Tersalin' : 'Copy ke chat'),
              ),
              FilledButton.tonalIcon(
                onPressed: _exportReady && !_downloading ? _downloadExport : null,
                icon: _downloading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded),
                label: Text(_downloading ? 'Menyimpan...' : 'Download'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pasteCtrl,
            onChanged: (_) => setState(() {}),
            maxLines: 6,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.35,
            ),
            decoration: InputDecoration(
              labelText: 'Paste balasan AI di sini',
              hintText:
                  '{"clips":[{"start_time":"00:05:12.000","end_time":"00:06:05.000",'
                  '"hook_text":"...","score":92}]}',
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          if (_pasteCtrl.text.trim().isNotEmpty && preview.ok)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${preview.clips.length} clip terdeteksi — siap dipakai',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (_pasteCtrl.text.trim().isNotEmpty && !preview.ok)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                preview.error ?? '',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canApply ? () => widget.onApply(_pasteCtrl.text) : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: AppColors.primary,
              ),
              child: Text(
                widget.applying ? 'Memakai hasil AI...' : 'Pakai hasil AI',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepChip(String title, String sub) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            sub,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
