import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_app.dart';
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
import 'package:prysm/ui/core/prysm_linear_progress.dart';

class FileAttachmentBubble extends StatefulWidget {
  final String fileName;
  final int? fileSize;
  final String timeString;
  final bool isSentByMe;
  final Widget tickWidget;
  final Future<Uint8List> Function() resolveBytes;
  final Widget? header;
  final ValueNotifier<double>? downloadProgress;

  const FileAttachmentBubble({
    required this.fileName,
    required this.timeString,
    required this.isSentByMe,
    required this.tickWidget,
    required this.resolveBytes,
    this.fileSize,
    this.header,
    this.downloadProgress,
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
  Timer? _progressTimer;
  Timer? _minDisplayTimer;
  double _simulatedProgress = 0.0;
  bool _showProgress = false;

  @override
  void initState() {
    super.initState();
    _category = ReadableFilePolicy.categorize(widget.fileName);
    _startProgressSimulation();
    if (SettingsService().enableFilePreview) {
      _loadPreview();
    } else {
      _resolveBytesOnly();
    }
  }

  Future<void> _resolveBytesOnly() async {
    try {
      final bytes = await widget.resolveBytes();
      if (!mounted) return;
      _completeProgress();
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      _completeProgress();
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    _progressTimer?.cancel();
    _minDisplayTimer?.cancel();
    super.dispose();
  }

  void _startProgressSimulation() {
    _simulatedProgress = 0.0;
    _showProgress = true;
    _progressTimer?.cancel();
    final size = widget.fileSize ?? 0;
    final intervalMs = size > 0
        ? (500000 / size).clamp(40, 120).toInt()
        : 80;
    _progressTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _simulatedProgress += 0.04;
      if (_simulatedProgress > 0.9) {
        _simulatedProgress = 0.9;
        timer.cancel();
      }
      widget.downloadProgress?.value = _simulatedProgress;
      if (mounted) setState(() {});
    });
  }

  void _completeProgress() {
    _progressTimer?.cancel();
    _simulatedProgress = 1.0;
    widget.downloadProgress?.value = 1.0;
    // Keep progress visible for at least 600ms so fast resolves still show the bar
    _minDisplayTimer?.cancel();
    _minDisplayTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() => _showProgress = false);
    });
  }

  Future<void> _loadPreview() async {
    if (!ReadableFilePolicy.supportsInlinePreview(_category) &&
        _category != FilePreviewCategory.blocked) {
      _completeProgress();
      setState(() => _loading = false);
      return;
    }

    if (widget.fileSize != null &&
        ReadableFilePolicy.exceedsPreviewLimit(widget.fileSize!)) {
      _completeProgress();
      setState(() {
        _loading = false;
        _previewSkippedDueToSize = true;
      });
      return;
    }

    _startProgressSimulation();

    try {
      final bytes = await widget.resolveBytes();
      if (!mounted) return;
      if (bytes.isEmpty) {
        _completeProgress();
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }

      if (ReadableFilePolicy.exceedsPreviewLimit(bytes.length)) {
        _completeProgress();
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
      _completeProgress();
      setState(() {
        _bytes = bytes;
        _preview = preview;
        _pdfController = pdfController;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      _completeProgress();
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
    if (_bytes == null) {
      _startProgressSimulation();
      setState(() => _loading = true);
    }
    final bytes = _bytes ?? await widget.resolveBytes();
    _completeProgress();
    if (!mounted) return;
    if (_bytes == null) {
      setState(() {
        _bytes = bytes;
        _loading = false;
        _loadFailed = false;
      });
    }
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
                  const SizedBox.shrink()
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
                      onPressed: (_loading && _bytes == null) ? null : _download,
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
                if (_showProgress)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PrysmLinearProgressIndicator(
                          value: _simulatedProgress.clamp(0.0, 1.0),
                          minHeight: 3,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Downloading… ${(_simulatedProgress * 100).toInt()}%',
                          style: TextStyle(
                            fontSize: 10,
                            color: onPrimary.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
