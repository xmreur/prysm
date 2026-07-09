import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/constants/media_constants.dart';
import 'package:prysm/screens/widgets/image_viewer_screen.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/ui/core/prysm_icons.dart';

/// Stable image bubble with async decrypt, aspect ratio, and fullscreen tap.
class ImageMessageBubble extends StatefulWidget {
  final ImageMessage message;
  final bool isSentByMe;
  final String timeString;
  final Widget tickWidget;
  final Future<Uint8List> Function()? decryptFromDb;
  final Widget? senderLabel;

  const ImageMessageBubble({
    required this.message,
    required this.isSentByMe,
    required this.timeString,
    required this.tickWidget,
    this.decryptFromDb,
    this.senderLabel,
    super.key,
  });

  @override
  State<ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends State<ImageMessageBubble> {
  static const _maxBubbleWidth = 240.0;

  CachedImage? _image;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(ImageMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.message.source != widget.message.source) {
      _image = null;
      _error = null;
      _resolveImage();
    }
  }

  Future<void> _resolveImage({bool force = false}) async {
    if (_loading && !force) return;

    final inline = _inlineBytes();
    if (inline != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final cached = await ImageAttachmentCache.resolve(
          messageId: widget.message.id,
          decrypt: () async => inline,
          inlineBytes: inline,
        );
        if (!mounted) return;
        setState(() {
          _image = cached;
          _loading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _error = e;
          _loading = false;
        });
      }
      return;
    }

    if (!isDeferredImageSource(widget.message.source)) {
      setState(() => _error = StateError('Unknown image source'));
      return;
    }

    final decrypt = widget.decryptFromDb;
    if (decrypt == null) {
      setState(() => _error = StateError('Missing decrypt callback'));
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final cached = await ImageAttachmentCache.resolve(
        messageId: widget.message.id,
        decrypt: decrypt,
      );
      if (!mounted) return;
      setState(() {
        _image = cached;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Uint8List? _inlineBytes() {
    final source = widget.message.source;
    if (!source.startsWith('data:image') || !source.contains(',')) {
      return null;
    }
    try {
      return base64Decode(source.split(',').last);
    } catch (_) {
      return null;
    }
  }

  void _openViewer() {
    final image = _image;
    if (image != null) {
      Navigator.push(
        context,
        PrysmPageRoute(page: ImageViewerScreen(
            bytes: image.bytes,
            mimeType: image.mimeType,
          ),
        ),
      );
      return;
    }

    if (isDeferredImageSource(widget.message.source) &&
        widget.decryptFromDb != null) {
      Navigator.push(
        context,
        PrysmPageRoute(page: ImageViewerScreen.deferred(
            messageId: widget.message.id,
            decryptFromDb: widget.decryptFromDb!,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final crossAlign = widget.isSentByMe
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;

    return Column(
      crossAxisAlignment: crossAlign,
      children: [
        if (widget.senderLabel != null) widget.senderLabel!,
        _buildImageArea(context),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.timeString,
              style: TextStyle(fontSize: 10, color: context.prysmStyle.tokens.textMuted),
            ),
            if (widget.isSentByMe) ...[
              const SizedBox(width: 4),
              widget.tickWidget,
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildImageArea(BuildContext context) {
    if (_loading && _image == null) {
      return _loadingPlaceholder(context);
    }
    if (_error != null && _image == null) {
      return _errorPlaceholder(context);
    }
    final image = _image;
    if (image == null) {
      return _loadingPlaceholder(context);
    }

    final aspect = image.aspectRatio.clamp(0.4, 2.5);
    return GestureDetector(
      onTap: _openViewer,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxBubbleWidth),
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              image.bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: 480,
              errorBuilder: (context, error, stackTrace) =>
                  _errorPlaceholder(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _loadingPlaceholder(BuildContext context) {
    return Container(
      width: _maxBubbleWidth,
      height: 160,
      decoration: BoxDecoration(
        color: context.prysmStyle.tokens.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: const PrysmProgressIndicator(size: 20),
        ),
      ),
    );
  }

  Widget _errorPlaceholder(BuildContext context) {
    return GestureDetector(
      onTap: () => _resolveImage(force: true),
      child: Container(
        width: _maxBubbleWidth,
        height: 120,
        decoration: BoxDecoration(
          color: context.prysmStyle.tokens.surfaceElevated,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              PrysmIcons.brokenImageOutlined,
              color: context.prysmStyle.tokens.textSecondary,
            ),
            const SizedBox(height: 6),
            Text(
              'Tap to retry',
              style: TextStyle(
                fontSize: 12,
                color: context.prysmStyle.tokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
