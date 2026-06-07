import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:prysm/util/pdf_system_open.dart';
import 'package:prysm/util/temp_file_helper.dart';
import 'package:prysm/util/video_preview_support.dart';
import 'package:video_player/video_player.dart';

class FullScreenVideoPlayer extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;

  const FullScreenVideoPlayer({
    required this.bytes,
    required this.fileName,
    super.key,
  });

  @override
  State<FullScreenVideoPlayer> createState() => _FullScreenVideoPlayerState();
}

class _FullScreenVideoPlayerState extends State<FullScreenVideoPlayer> {
  VideoPlayerController? _controller;
  bool _loading = true;
  bool _openingExternally = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (VideoPreviewSupport.canPlayInApp) {
      _init();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final path = await TempFileHelper.write(widget.bytes, widget.fileName);
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _openWithSystem() async {
    setState(() => _openingExternally = true);
    try {
      final message = await PdfSystemOpen.open(widget.bytes, widget.fileName);
      if (!mounted) return;
      if (message != null && message != 'done') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open video: $e')),
      );
    } finally {
      if (mounted) setState(() => _openingExternally = false);
    }
  }

  Widget _externalFallback(BuildContext context, {String? reason}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam, size: 48),
            const SizedBox(height: 16),
            Text(
              'Video',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              reason ??
                  'In-app video playback is not available on this platform.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openingExternally ? null : _openWithSystem,
              icon: _openingExternally
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_new),
              label: Text(_openingExternally ? 'Opening…' : 'Open with system player'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!VideoPreviewSupport.canPlayInApp) {
      return _externalFallback(context);
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null || _controller == null || !_controller!.value.isInitialized) {
      return _externalFallback(
        context,
        reason: _error ?? 'Could not play video in app.',
      );
    }

    final controller = _controller!;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: VideoPlayer(controller),
        ),
        const SizedBox(height: 16),
        VideoProgressIndicator(
          controller,
          allowScrubbing: true,
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 40,
              icon: Icon(
                controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
              onPressed: () {
                setState(() {
                  if (controller.value.isPlaying) {
                    controller.pause();
                  } else {
                    controller.play();
                  }
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}

class FullScreenAudioPlayer extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  final String? mimeType;

  const FullScreenAudioPlayer({
    required this.bytes,
    required this.fileName,
    this.mimeType,
    super.key,
  });

  @override
  State<FullScreenAudioPlayer> createState() => _FullScreenAudioPlayerState();
}

class _FullScreenAudioPlayerState extends State<FullScreenAudioPlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _loading = true;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state == PlayerState.playing);
    });
    _player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
    });
    _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _init();
  }

  Future<void> _init() async {
    try {
      final path = await TempFileHelper.write(widget.bytes, widget.fileName);
      await _player.setSource(DeviceFileSource(path));
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.audiotrack, size: 64),
            const SizedBox(height: 24),
            Text(
              widget.fileName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            Slider(
              value: _duration.inMilliseconds == 0
                  ? 0
                  : _position.inMilliseconds
                      .clamp(0, _duration.inMilliseconds)
                      .toDouble(),
              max: _duration.inMilliseconds == 0
                  ? 1
                  : _duration.inMilliseconds.toDouble(),
              onChanged: _duration.inMilliseconds == 0
                  ? null
                  : (value) => _player.seek(
                        Duration(milliseconds: value.round()),
                      ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_format(_position)),
                Text(_format(_duration)),
              ],
            ),
            const SizedBox(height: 8),
            IconButton(
              iconSize: 48,
              icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle),
              onPressed: () async {
                if (_playing) {
                  await _player.pause();
                } else {
                  await _player.resume();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
