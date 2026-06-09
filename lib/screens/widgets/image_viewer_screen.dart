import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/util/image_download_helper.dart';

/// Full-screen pinch-zoom image viewer.
class ImageViewerScreen extends StatefulWidget {
  final Uint8List? bytes;
  final String? messageId;
  final Future<Uint8List> Function()? decryptFromDb;
  final String? mimeType;

  const ImageViewerScreen({
    required this.bytes,
    this.mimeType,
    super.key,
  })  : messageId = null,
        decryptFromDb = null;

  const ImageViewerScreen.deferred({
    required this.messageId,
    required this.decryptFromDb,
    super.key,
  })  : bytes = null,
        mimeType = null;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  CachedImage? _image;
  Object? _error;
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.bytes != null) {
      _loadInline(widget.bytes!);
    } else {
      _loadDeferred();
    }
  }

  Future<void> _loadInline(Uint8List bytes) async {
    try {
      final cached = await ImageAttachmentCache.resolve(
        messageId: '_inline_viewer',
        decrypt: () async => bytes,
        inlineBytes: bytes,
      );
      if (!mounted) return;
      setState(() {
        _image = cached;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _loadDeferred() async {
    final id = widget.messageId;
    final decrypt = widget.decryptFromDb;
    if (id == null || decrypt == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final cached = await ImageAttachmentCache.resolve(
        messageId: id,
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

  Future<void> _saveImage() async {
    final image = _image;
    if (image == null || _saving) return;

    setState(() => _saving = true);
    try {
      final ext = ImageDownloadHelper.extensionForMime(image.mimeType);
      final baseName = widget.messageId != null
          ? 'prysm_${widget.messageId}.$ext'
          : null;
      await ImageDownloadHelper.saveToDevice(
        context,
        bytes: image.bytes,
        mimeType: widget.mimeType ?? image.mimeType,
        baseName: baseName,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final canSave = _image != null && !_loading;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: isDark ? Colors.white : Colors.black87,
        actions: [
          if (canSave)
            IconButton(
              tooltip: 'Save image',
              onPressed: _saving ? null : _saveImage,
              icon: _saving
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    )
                  : const Icon(Icons.download_outlined),
            ),
        ],
      ),
      body: Center(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const CircularProgressIndicator();
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(
            'Could not load image',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (widget.decryptFromDb != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: _loadDeferred,
              child: const Text('Retry'),
            ),
          ],
        ],
      );
    }
    final image = _image;
    if (image == null) {
      return const SizedBox.shrink();
    }
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4,
      child: Image.memory(
        image.bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    );
  }
}
