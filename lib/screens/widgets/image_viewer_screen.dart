import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'dart:typed_data';

import 'package:prysm/services/image_attachment_cache.dart';
import 'package:prysm/util/image_download_helper.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

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
    final isDark = context.prysmStyle.tokens.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final canSave = _image != null && !_loading;

    return PrysmPage(
      backgroundColor: bg,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        color: isDark ? const Color(0xFFFFFFFF) : const Color(0x87000000),
        onPressed: () => Navigator.of(context).pop(),
      ),
      actions: [
        if (canSave)
          PrysmIconButton(
            icon: PrysmIcons.downloadOutlined,
            tooltip: 'Save image',
            color: isDark ? const Color(0xFFFFFFFF) : const Color(0x87000000),
            onPressed: _saving ? null : _saveImage,
          ),
      ],
      body: Center(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const PrysmProgressIndicator();
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PrysmIcons.brokenImageOutlined,
            size: 48,
            color: context.prysmStyle.tokens.danger,
          ),
          const SizedBox(height: 12),
          Text(
            'Could not load image',
            style: context.prysmStyle.bodyStyle,
          ),
          if (widget.decryptFromDb != null) ...[
            const SizedBox(height: 12),
            PrysmTextButton(label: 'Retry', onPressed: _loadDeferred),
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
