import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';
import 'package:prysm/screens/file_preview_screen.dart';
import 'package:prysm/screens/widgets/file_preview_content.dart';
import 'package:prysm/services/file_preview_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/file_download_helper.dart';
import 'package:prysm/util/readable_file_policy.dart';
import 'package:prysm/ui/chat/prysm_bubble_renderer.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_progress.dart';

class FileAttachmentBubble extends StatefulWidget {
  final String fileName;
  final int? fileSize;
  final String timeString;
  final bool isSentByMe;
  final Widget tickWidget;
  final Future<Uint8List> Function() resolveBytes;
  final Widget? header;

  const FileAttachmentBubble({
    required this.fileName,
    required this.timeString,
    required this.isSentByMe,
    required this.tickWidget,
    required this.resolveBytes,
    this.fileSize,
    this.header,
    super.key,
  });

  @override
  State<FileAttachmentBubble> createState() => _FileAttachmentBubbleState();
}

class _FileAttachmentBubbleState extends State<FileAttachmentBubble> {
  late final FilePreviewCategory _category;
  FilePreviewData? _preview;
  Uint8List? _bytes;
  PdfControllerPinch? _pdfController;
  bool _loading = true;
  bool _loadFailed = false;
  bool _previewSkippedDueToSize = false;

  @override
  void initState() {
    super.initState();
    _category = ReadableFilePolicy.categorize(widget.fileName);
    if (SettingsService().enableFilePreview) {
      _loadPreview();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    if (!ReadableFilePolicy.supportsInlinePreview(_category) &&
        _category != FilePreviewCategory.blocked) {
      setState(() => _loading = false);
      return;
    }

    if (widget.fileSize != null &&
        ReadableFilePolicy.exceedsPreviewLimit(widget.fileSize!)) {
      setState(() {
        _loading = false;
        _previewSkippedDueToSize = true;
      });
      return;
    }

    try {
      final bytes = await widget.resolveBytes();
      if (!mounted) return;
      if (bytes.isEmpty) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }

      if (ReadableFilePolicy.exceedsPreviewLimit(bytes.length)) {
        setState(() {
          _loading = false;
          _previewSkippedDueToSize = true;
        });
        return;
      }

      final preview = await FilePreviewService.buildPreview(
        fileName: widget.fileName,
        bytes: bytes,
        inline: true,
      );

      PdfControllerPinch? pdfController;
      if (preview.category == FilePreviewCategory.pdf && preview.pdf != null) {
        pdfController =
            await FilePreviewService.openPdfController(preview.pdf!.documentBytes);
      }

      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _preview = preview;
        _pdfController = pdfController;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _openFullPreview() {
    if (!SettingsService().enableFilePreview) return;
    Navigator.of(context).push(
      PrysmPageRoute(page: FilePreviewScreen(
          fileName: widget.fileName,
          fileSize: widget.fileSize,
          bytesFuture: widget.resolveBytes(),
          category: _category,
        ),
      ),
    );
  }

  Future<void> _download() async {
    final bytes = _bytes ?? await widget.resolveBytes();
    if (!mounted) return;
    await FileDownloadHelper.download(
      context,
      fileName: widget.fileName,
      bytes: bytes,
      category: _category,
    );
  }

  String get _fileSizeString {
    if (widget.fileSize == null) return '';
    final sizeInKB = widget.fileSize! / 1024;
    if (sizeInKB < 1024) {
      return '${sizeInKB.toStringAsFixed(1)} KB';
    }
    return '${(sizeInKB / 1024).toStringAsFixed(1)} MB';
  }

  bool get _hasTappablePreview =>
      _preview != null && ReadableFilePolicy.supportsInlinePreview(_category);

  Widget _wrapPreviewTap(Widget child) {
    if (!_hasTappablePreview) return child;
    return GestureDetector(
      onTap: _openFullPreview,
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width * 0.55;
    final bubbleColor = prysmBubbleBackground(
      context,
      isSentByMe: widget.isSentByMe,
    );
    final onPrimary = prysmBubbleTextColor(
      context,
      isSentByMe: widget.isSentByMe,
    );

    return Column(
      crossAxisAlignment:
          widget.isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (widget.header != null) widget.header!,
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_category == FilePreviewCategory.blocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Icon(PrysmIcons.warningAmberRounded,
                            size: 18, color: onPrimary.withValues(alpha: 0.9)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Preview unavailable',
                            style: TextStyle(
                              fontSize: 11,
                              color: onPrimary.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (_loading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: PrysmProgressIndicator(size: 20),
                      ),
                    ),
                  )
                else if (_hasTappablePreview)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _wrapPreviewTap(
                      InlineFilePreview(
                        preview: _preview!,
                        fileName: widget.fileName,
                        pdfController: _pdfController,
                      ),
                    ),
                  )
                else if (_previewSkippedDueToSize)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Icon(PrysmIcons.insertDriveFile, color: onPrimary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Preview unavailable (file too large)',
                            style: TextStyle(
                              fontSize: 11,
                              color: onPrimary.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (_loadFailed)
                  const SizedBox.shrink()
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Icon(PrysmIcons.insertDriveFile, color: onPrimary),
                  ),
                Row(
                  children: [
                    PrysmIconButton(
                      icon: PrysmIcons.downloadOutlined,
                      color: onPrimary,
                      tooltip: 'Download',
                      onPressed: _loading ? null : _download,
                    ),
                    Expanded(
                      child: Text(
                        widget.fileName,
                        style: TextStyle(color: onPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (_fileSizeString.isNotEmpty)
                      Text(
                        _fileSizeString,
                        style: TextStyle(
                          fontSize: 10,
                          color: onPrimary.withValues(alpha: 0.8),
                        ),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.timeString,
                          style: TextStyle(
                            fontSize: 10,
                            color: onPrimary.withValues(alpha: 0.8),
                          ),
                        ),
                        if (widget.isSentByMe) ...[
                          const SizedBox(width: 4),
                          widget.tickWidget,
                        ],
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
