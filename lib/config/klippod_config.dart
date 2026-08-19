/// Konfigurasi integrasi YT Downloader → Klippod.
/// Kalau package name Play Store beda, ganti [packageName] saja.
class KlippodConfig {
  /// applicationId Klippod (harus sama dengan Play Store / build.gradle Klippod)
  static const packageName = 'com.jenovatech.klippod';

  /// Deep link scheme yang akan didaftarkan di Klippod
  static const scheme = 'klippod';

  /// Host deep link: klippod://import
  static const importHost = 'import';

  /// Host deep link multi-klip: klippod://import-clips
  static const importClipsHost = 'import-clips';

  static String get playStoreUrl =>
      'https://play.google.com/store/apps/details?id=$packageName';

  static String get playStoreMarketUrl => 'market://details?id=$packageName';
}
