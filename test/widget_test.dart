import 'package:flutter_test/flutter_test.dart';

import 'package:yt_downloader/main.dart';

void main() {
  testWidgets('App boots to home', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await tester.pumpWidget(const YtDownloaderApp());
    await tester.pump();
    expect(find.text('YT Downloader'), findsOneWidget);
  });
}
