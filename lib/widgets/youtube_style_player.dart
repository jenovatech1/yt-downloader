import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../utils/format_utils.dart';

class YoutubeStylePlayer extends StatefulWidget {
  const YoutubeStylePlayer({
    super.key,
    required this.controller,
    this.borderRadius = 12,
  });

  final VideoPlayerController controller;
  final double borderRadius;

  @override
  State<YoutubeStylePlayer> createState() => _YoutubeStylePlayerState();
}

class _YoutubeStylePlayerState extends State<YoutubeStylePlayer> {
  bool _showControls = true;
  bool _isScrubbing = false;
  double _scrubValue = 0;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (!_isScrubbing && mounted) {
      setState(() {});
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (widget.controller.value.isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && !_isScrubbing) {
          setState(() => _showControls = false);
        }
      });
    }
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _togglePlay() {
    final c = widget.controller;
    if (c.value.isPlaying) {
      c.pause();
      setState(() => _showControls = true);
      _hideTimer?.cancel();
    } else {
      c.play();
      _scheduleHide();
    }
  }

  Duration get _position {
    if (_isScrubbing) {
      final duration = widget.controller.value.duration;
      return Duration(
        milliseconds: (duration.inMilliseconds * _scrubValue).round(),
      );
    }
    return widget.controller.value.position;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final duration = c.value.duration;
    final maxMs = duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
    final sliderValue = _isScrubbing
        ? _scrubValue
        : (c.value.position.inMilliseconds / maxMs).clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: ColoredBox(
        color: Colors.black,
        child: GestureDetector(
          onTap: _toggleControls,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio == 0
                      ? 16 / 9
                      : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
              AnimatedOpacity(
                opacity: _showControls ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.45),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.65),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (!c.value.isPlaying || _showControls)
                IconButton(
                  onPressed: _togglePlay,
                  iconSize: 56,
                  color: Colors.white.withValues(alpha: 0.9),
                  icon: Icon(
                    c.value.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded,
                  ),
                ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 4,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                            activeTrackColor: const Color(0xFF8BC53F),
                            inactiveTrackColor:
                                Colors.white.withValues(alpha: 0.25),
                            thumbColor: const Color(0xFF8BC53F),
                          ),
                          child: Slider(
                            value: sliderValue,
                            onChangeStart: (_) {
                              setState(() {
                                _isScrubbing = true;
                                _scrubValue = sliderValue;
                                _showControls = true;
                              });
                              _hideTimer?.cancel();
                            },
                            onChanged: (v) {
                              setState(() => _scrubValue = v);
                            },
                            onChangeEnd: (v) async {
                              final target = Duration(
                                milliseconds: (maxMs * v).round(),
                              );
                              await c.seekTo(target);
                              if (mounted) {
                                setState(() => _isScrubbing = false);
                                _scheduleHide();
                              }
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                          child: Row(
                            children: [
                              Text(
                                FormatUtils.duration(_position),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Text(
                                ' / ',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                FormatUtils.duration(duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                onPressed: _togglePlay,
                                icon: Icon(
                                  c.value.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
