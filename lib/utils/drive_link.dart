// Parse Google Drive file links.

String? driveFileId(String value) {
  final url = _parse(value);
  if (url == null) return null;
  final host = url.host.toLowerCase();
  if (host != 'drive.google.com' &&
      host != 'docs.google.com' &&
      host != 'drive.usercontent.google.com') {
    return null;
  }
  final pathMatch = RegExp(
    r'^/file/d/([\w-]+)(?:/(?:view|edit|preview))?/?$',
  ).firstMatch(url.path);
  final id = pathMatch?.group(1) ??
      ((RegExp(r'^/(?:open|uc|download)$').hasMatch(url.path))
          ? url.queryParameters['id']
          : null);
  if (id == null) return null;
  if (!RegExp(r'^[\w-]{28,}$').hasMatch(id)) return null;
  return id;
}

bool looksLikeDriveUrl(String value) {
  final host = _parse(value)?.host.toLowerCase();
  if (host == null) return false;
  return host == 'drive.google.com' ||
      host == 'docs.google.com' ||
      host == 'drive.usercontent.google.com';
}

String? normalizeDriveViewUrl(String value) {
  final id = driveFileId(value);
  if (id == null) return null;
  return 'https://drive.google.com/file/d/$id/view';
}

Uri? _parse(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return null;
  try {
    final withScheme =
        RegExp(r'^https?:\/\/', caseSensitive: false).hasMatch(raw)
            ? raw
            : 'https://$raw';
    final url = Uri.parse(withScheme);
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    return url;
  } catch (_) {
    return null;
  }
}
