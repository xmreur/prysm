import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';
import 'package:prysm/screens/widgets/inline_video_preview.dart';
import 'package:prysm/screens/widgets/media_preview_player.dart';
import 'package:prysm/services/file_preview_service.dart';
import 'package:prysm/util/file_download_helper.dart';
import 'package:prysm/util/pdf_system_open.dart';
import 'package:prysm/util/readable_file_policy.dart';
import 'package:prysm/ui/core/prysm_button.dart';

class FilePreviewContent extends StatefulWidget {
  final FilePreviewData preview;
  final PdfControllerPinch? pdfController;
  final String fileName;
  final Uint8List? bytes;

  const FilePreviewContent({
    required this.preview,
    required this.fileName,
    this.pdfController,
    this.bytes,
    super.key,
  });

  @override
  State<FilePreviewContent> createState() => _FilePreviewContentState();
}

class _FilePreviewContentState extends State<FilePreviewContent> {
  bool _openingExternally = false;
  bool _downloading = false;
  final PageController _slidePageController = PageController();

  @override
  void dispose() {
    _slidePageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.preview.category) {
      FilePreviewCategory.blocked => _blockedBody(context),
      FilePreviewCategory.binary => _binaryBody(context),
      FilePreviewCategory.text || FilePreviewCategory.document =>
        _textBody(widget.preview.text),
      FilePreviewCategory.spreadsheet =>
        _spreadsheetBody(widget.preview.spreadsheet),
      FilePreviewCategory.pdf => _pdfBody(context),
      FilePreviewCategory.presentation =>
        _presentationBody(context, widget.preview.presentation),
      FilePreviewCategory.video => _videoBody(),
      FilePreviewCategory.audio => _audioBody(),
    };
  }

  Widget _blockedBody(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PrysmIcons.warningAmberRounded,
                size: 48, color: context.prysmStyle.tokens.danger),
            const SizedBox(height: 16),
            Text(
              'Preview unavailable',
              style: context.prysmStyle.headlineStyle,
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.fileName} may be harmful. Download only if you trust the sender.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.prysmStyle.tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _binaryBody(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(PrysmIcons.insertDriveFile, size: 48),
            const SizedBox(height: 16),
            Text(
              'No preview available',
              style: context.prysmStyle.headlineStyle,
            ),
            const SizedBox(height: 8),
            Text(
              widget.fileName,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.prysmStyle.tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textBody(TextPreviewData? data) {
    final text = data?.fullText ?? '';
    if (text.isEmpty) {
      return const Center(child: Text('Empty file'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
      ),
    );
  }

  Widget _spreadsheetBody(SpreadsheetPreviewData? data) {
    final rows = data?.rows ?? [];
    if (rows.isEmpty) {
      return const Center(child: Text('Could not read spreadsheet'));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(
            color: context.prysmStyle.tokens.divider,
            width: 0.5,
          ),
          children: [
            TableRow(
              children: List.generate(
                rows.first.length,
                (i) => Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    'Col ${i + 1}',
                    style: context.prysmStyle.titleStyle.copyWith(fontSize: 12),
                  ),
                ),
              ),
            ),
            ...rows.map(
              (row) => TableRow(
                children: row
                    .map(
                      (cell) => Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(cell, maxLines: 3),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pdfBody(BuildContext context) {
    if (widget.pdfController != null) {
      return PdfViewPinch(controller: widget.pdfController!);
    }
    return _inAppDownloadFallback(
      context,
      icon: PrysmIcons.pictureAsPdf,
      title: 'PDF document',
      subtitle: 'In-app PDF preview is not available on this platform.',
      allowExternalOpen: true,
    );
  }

  Widget _presentationBody(
    BuildContext context,
    PresentationPreviewData? data,
  ) {
    if (data?.legacyFormat == true) {
      return _inAppDownloadFallback(
        context,
        icon: PrysmIcons.slideshow,
        title: 'Presentation',
        subtitle:
            'Slide preview is not supported for this format in Prysm.',
        allowExternalOpen: true,
      );
    }

    final slides = data?.slides ?? [];
    if (slides.isNotEmpty) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '${slides.length} slide${slides.length == 1 ? '' : 's'}',
              style: context.prysmStyle.titleStyle,
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _slidePageController,
              itemCount: slides.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Slide ${index + 1}',
                        style: context.prysmStyle.titleStyle,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(
                            slides[index],
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    final text = data?.fullText ?? '';
    if (text.isEmpty ||
        text == 'Could not read presentation' ||
        (data?.lines.isNotEmpty == true &&
            data!.lines.first == 'Could not read presentation')) {
      return _inAppDownloadFallback(
        context,
        icon: PrysmIcons.slideshow,
        title: 'Presentation',
        subtitle: 'Could not read presentation content in Prysm.',
        allowExternalOpen: true,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14),
      ),
    );
  }

  Widget _videoBody() {
    final bytes = widget.bytes ?? widget.preview.media?.mediaBytes;
    if (bytes == null || bytes.isEmpty) {
      return const Center(child: Text('Video not ready'));
    }
    return FullScreenVideoPlayer(bytes: bytes, fileName: widget.fileName);
  }

  Widget _audioBody() {
    final bytes = widget.bytes ?? widget.preview.media?.mediaBytes;
    if (bytes == null || bytes.isEmpty) {
      return const Center(child: Text('Audio not ready'));
    }
    return FullScreenAudioPlayer(
      bytes: bytes,
      fileName: widget.fileName,
      mimeType: widget.preview.media?.mimeType,
    );
  }

  Widget _inAppDownloadFallback(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    bool allowExternalOpen = false,
  }) {
    final bytes = widget.bytes;
    final category = widget.preview.category;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(title, style: context.prysmStyle.headlineStyle),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.prysmStyle.tokens.textMuted),
            ),
            if (bytes != null && bytes.isNotEmpty) ...[
              const SizedBox(height: 24),
              PrysmButton(
                label: _downloading ? 'Downloading…' : 'Download',
                onPressed: _downloading ? null : () => _download(bytes, category),
              ),
              if (allowExternalOpen) ...[
                const SizedBox(height: 12),
                PrysmButton(
                  label: _openingExternally
                      ? 'Opening…'
                      : 'Open with system app',
                  variant: PrysmButtonVariant.secondary,
                  onPressed:
                      _openingExternally ? null : () => _openWithSystem(bytes),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _download(Uint8List bytes, FilePreviewCategory category) async {
    setState(() => _downloading = true);
    try {
      await FileDownloadHelper.download(
        context,
        fileName: widget.fileName,
        bytes: bytes,
        category: category,
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _openWithSystem(Uint8List bytes) async {
    setState(() => _openingExternally = true);
    try {
      final message = await PdfSystemOpen.open(bytes, widget.fileName);
      if (!mounted) return;
      if (message != null && message != 'done') {
        showPrysmToast(context, message);
      }
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not open file: $e');
    } finally {
      if (mounted) setState(() => _openingExternally = false);
    }
  }
}

class InlineFilePreview extends StatelessWidget {
  final FilePreviewData preview;
  final String fileName;
  final PdfControllerPinch? pdfController;

  const InlineFilePreview({
    required this.preview,
    required this.fileName,
    this.pdfController,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final surface =
        context.prysmStyle.tokens.surface.withValues(alpha: 0.35);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 120),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(6),
      ),
      child: switch (preview.category) {
        FilePreviewCategory.text || FilePreviewCategory.document =>
          _textSnippet(preview.text, context),
        FilePreviewCategory.spreadsheet =>
          _sheetSnippet(preview.spreadsheet, context),
        FilePreviewCategory.pdf => _pdfSnippet(context),
        FilePreviewCategory.presentation =>
          _presentationSnippet(preview.presentation, context),
        FilePreviewCategory.video => InlineVideoPreview(
            bytes: preview.media!.mediaBytes,
            fileName: fileName,
            thumbnailBytes: preview.media?.thumbnailBytes,
          ),
        FilePreviewCategory.audio => _audioSnippet(context),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Widget _textSnippet(TextPreviewData? data, BuildContext context) {
    final lines = data?.lines ?? [];
    if (lines.isEmpty) {
      return Text('…', style: TextStyle(color: context.prysmStyle.tokens.textMuted));
    }
    return Text(
      lines.join('\n'),
      maxLines: ReadableFilePolicy.textSnippetLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 11,
        color: context.prysmStyle.tokens.onAccent.withValues(alpha: 0.9),
      ),
    );
  }

  Widget _sheetSnippet(SpreadsheetPreviewData? data, BuildContext context) {
    final rows = data?.rows ?? [];
    if (rows.isEmpty) {
      return Text('Spreadsheet', style: TextStyle(color: context.prysmStyle.tokens.textMuted));
    }
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: rows
          .map(
            (row) => TableRow(
              children: row
                  .map(
                    (cell) => Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 2),
                      child: Text(
                        cell,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: context.prysmStyle.tokens.textPrimary
                              .withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          )
          .toList(),
    );
  }

  Widget _pdfSnippet(BuildContext context) {
    if (pdfController != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: PdfViewPinch(
          controller: pdfController!,
          scrollDirection: Axis.vertical,
        ),
      );
    }
    return _iconLabel(context, PrysmIcons.pictureAsPdf, 'PDF document');
  }

  Widget _presentationSnippet(
    PresentationPreviewData? data,
    BuildContext context,
  ) {
    if (data?.legacyFormat == true) {
      return _iconLabel(context, PrysmIcons.slideshow, 'Presentation');
    }
    final lines = data?.lines ?? [];
    if (lines.isEmpty) {
      return _iconLabel(context, PrysmIcons.slideshow, 'Presentation');
    }
    return Text(
      lines.join('\n'),
      maxLines: ReadableFilePolicy.textSnippetLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        color: context.prysmStyle.tokens.onAccent.withValues(alpha: 0.9),
      ),
    );
  }

  Widget _audioSnippet(BuildContext context) {
    return _iconLabel(context, PrysmIcons.audiotrack, 'Audio');
  }

  Widget _iconLabel(BuildContext context, IconData icon, String label) {
    return Row(
      children: [
        Icon(
          icon,
          size: 28,
          color: context.prysmStyle.tokens.onAccent.withValues(alpha: 0.9),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: context.prysmStyle.tokens.onAccent.withValues(alpha: 0.9),
            ),
          ),
        ),
      ],
    );
  }
}
