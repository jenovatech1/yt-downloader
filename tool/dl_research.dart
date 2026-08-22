import 'dart:async';
import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<int> explodeDl(YoutubeExplode yt, StreamInfo info, {int max = 3*1024*1024}) async {
  var n = 0;
  await for (final c in yt.videos.streamsClient.get(info).timeout(const Duration(seconds: 30), onTimeout: (s) {
    s.addError(TimeoutException('stall@$n'));
    s.close();
  })) {
    n += c.length;
    if (n >= max) break;
  }
  return n;
}

Future<void> main() async {
  // Strategy A: one manifest, download video then audio sequential with SAME yt
  {
    print('=== A: same manifest sequential ===');
    final yt = YoutubeExplode();
    try {
      final m = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
      final v = m.videoOnly.first;
      final a = m.audioOnly.first;
      print('v=${await explodeDl(yt,v)} a=${await explodeDl(yt,a)}');
    } catch (e) {
      print('A FAIL $e');
    } finally { yt.close(); }
  }

  // Strategy B: SEPARATE manifest for each stream (official warning workaround)
  {
    print('=== B: fresh manifest per stream ===');
    final yt = YoutubeExplode();
    try {
      final m1 = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
      final v = m1.videoOnly.where((s)=>s.videoResolution.height<=360).first;
      final n1 = await explodeDl(yt, v);
      print('video ok $n1');
      final m2 = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
      final a = m2.audioOnly.first;
      final n2 = await explodeDl(yt, a);
      print('audio ok $n2');
    } catch (e) {
      print('B FAIL $e');
    } finally { yt.close(); }
  }

  // Strategy C: muxed only
  {
    print('=== C: muxed only ===');
    final yt = YoutubeExplode();
    try {
      final m = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
      if (m.muxed.isEmpty) { print('no muxed'); }
      else {
        final n = await explodeDl(yt, m.muxed.first, max: 5*1024*1024);
        print('muxed ok $n / ${m.muxed.first.size.totalBytes}');
      }
    } catch (e) {
      print('C FAIL $e');
    } finally { yt.close(); }
  }

  // Strategy D: FULL download of small audio via explode (complete file)
  {
    print('=== D: full small audio file ===');
    final yt = YoutubeExplode();
    try {
      final m = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
      final a = (m.audioOnly.toList()..sort((x,y)=>x.size.totalBytes.compareTo(y.size.totalBytes))).first;
      print('target ${a.size.totalBytes} ${a.bitrate}');
      final file = File('tool/_test_audio.bin');
      final sink = file.openWrite();
      var n = 0;
      final sw = Stopwatch()..start();
      await for (final c in yt.videos.streamsClient.get(a)) {
        sink.add(c);
        n += c.length;
      }
      await sink.close();
      print('FULL audio OK $n in ${sw.elapsedMilliseconds}ms exists=${file.existsSync()} len=${file.lengthSync()}');
      file.deleteSync();
    } catch (e) {
      print('D FAIL $e');
    } finally { yt.close(); }
  }

  // Strategy E: ios client streams download
  {
    print('=== E: ios client full audio ===');
    final yt = YoutubeExplode();
    try {
      final m = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw', ytClients: [YoutubeApiClient.ios]);
      final a = m.audioOnly.first;
      var n = 0;
      await for (final c in yt.videos.streamsClient.get(a)) {
        n += c.length;
      }
      print('ios audio FULL OK $n / ${a.size.totalBytes}');
    } catch (e) {
      print('E FAIL $e');
    } finally { yt.close(); }
  }
}
