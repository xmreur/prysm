import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:prysm/util/temp_file_helper.dart';
import 'package:prysm/util/video_preview_support.dart';
import 'package:video_player/video_player.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';

/// Inline chat bubble video preview: thumbnail image, first video frame, or icon.
class InlineVideoPreview extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  final Uint8List? thumbnailBytes;

  const InlineVideoPreview({
    required this.bytes,
    required this.fileName,
    this.thumbnailBytes,
    super.key,
  });

  @override
  State<InlineVideoPreview> createState() => _InlineVideoPreviewState();
}

class _InlineVideoPreviewState extends State<InlineVideoPreview> {
  VideoPlayerController? _controller;
  bool _frameReady = false;
  bool _loadingFrame = false;

  @override
  void initState() {
    super.initState();
    if ((widget.thumbnailBytes == null || widget.thumbnailBytes!.isEmpty) &&
        VideoPreviewSupport.canPlayInApp) {
      _loadingFrame = true;
      _loadFirstFrame();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _loadFirstFrame() async {
    try {
      final path = await TempFileHelper.write(widget.bytes, widget.fileName);
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      await controller.pause();
      await controller.seekTo(const Duration(milliseconds: 100));
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _frameReady = true;
        _loadingFrame = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _frameReady = false;
          _loadingFrame = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPrimary = context.prysmStyle.tokens.onAccent.withValues(alpha: 0.9);

    if (widget.thumbnailBytes != null && widget.thumbnailBytes!.isNotEmpty) {
      return _playOverlay(
        context,
        Image.memory(
          widget.thumbnailBytes!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: 100,
        ),
      );
    }

    if (_loadingFrame) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: const PrysmProgressIndicator(size: 20),
        ),
      );
    }

    if (_frameReady && _controller != null && _controller!.value.isInitialized) {
      return _playOverlay(
        context,
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 100,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _controller!.value.size.width,
                height: _controller!.value.size.height,
                child: VideoPlayer(_controller!),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        Icon(PrysmIcons.videocam, size: 28, color: onPrimary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Video',
            style: TextStyle(fontSize: 12, color: onPrimary),
          ),
        ),
      ],
    );
  }

  Widget _playOverlay(BuildContext context, Widget child) {
    return Stack(
      alignment: Alignment.center,
      children: [
        child,
        Icon(
          PrysmIcons.playCircleFill,
          size: 36,
          color: context.prysmStyle.tokens.onAccent.withValues(alpha: 0.95),
        ),
      ],
    );
  }
}
