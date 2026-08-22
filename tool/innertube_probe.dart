import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  final uri = Uri.parse('https://www.youtube.com/youtubei/v1/search?prettyPrint=false');
  final body = {
    'context': {
      'client': {
        'clientName': 'WEB',
        'clientVersion': '2.20250312.04.00',
        'hl': 'en',
        'gl': 'US',
      }
    },
    'query': 'flutter tutorial',
  };
  final res = await http.post(
    uri,
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      'X-Youtube-Client-Name': '1',
      'X-Youtube-Client-Version': '2.20250312.04.00',
    },
    body: jsonEncode(body),
  );
  print('status=${res.statusCode} len=${res.body.length}');
  if (res.statusCode != 200) {
    print(res.body.substring(0, res.body.length.clamp(0, 400)));
    return;
  }
  final json = jsonDecode(res.body) as Map<String, dynamic>;
  final contents = (((json['contents'] as Map?)?['twoColumnSearchResultsRenderer'] as Map?)?['primaryContents'] as Map?)?['sectionListRenderer'];
  print('has section=${contents != null}');
  // count videoRenderer
  final s = res.body;
  print('videoRenderer count=${RegExp(r'"videoRenderer"').allMatches(s).length}');
}
