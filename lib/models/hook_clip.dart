class HookClip {
  const HookClip({
    required this.index,
    required this.startSec,
    required this.endSec,
    required this.filePath,
    this.title,
    this.hookScore,
  });

  final int index;
  final double startSec;
  final double endSec;
  final String filePath;
  final String? title;
  final double? hookScore;

  Duration get duration =>
      Duration(milliseconds: ((endSec - startSec) * 1000).round());
}
