import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';
import 'package:prysm/services/file_preview_service.dart';
import 'package:prysm/util/pdf_system_open.dart';
import 'package:prysm/util/readable_file_policy.dart';

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
  bool _openingPdf = false;

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
    };
  }

  Widget _blockedBody(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Preview unavailable',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.fileName} may be harmful. Download only if you trust the sender.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor),
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
            const Icon(Icons.insert_drive_file, size: 48),
            const SizedBox(height: 16),
            Text(
              'No preview available',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.fileName,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor),
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
      child: SelectableText(
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
        child: DataTable(
          columns: List.generate(
            rows.first.length,
            (i) => DataColumn(label: Text('Col ${i + 1}')),
          ),
          rows: rows
              .map(
                (row) => DataRow(
                  cells: row
                      .map((cell) => DataCell(Text(cell, maxLines: 3)))
                      .toList(),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _pdfBody(BuildContext context) {
    if (widget.pdfController != null) {
      return PdfViewPinch(controller: widget.pdfController!);
    }
    return _pdfFallbackBody(context);
  }

  Widget _pdfFallbackBody(BuildContext context) {
    final bytes = widget.bytes;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf, size: 48),
            const SizedBox(height: 16),
            Text(
              'PDF document',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'In-app PDF preview is not available on this platform.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            if (bytes != null && bytes.isNotEmpty) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _openingPdf ? null : () => _openWithSystem(bytes),
                icon: _openingPdf
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.open_in_new),
                label: Text(_openingPdf ? 'Opening…' : 'Open with system viewer'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openWithSystem(Uint8List bytes) async {
    setState(() => _openingPdf = true);
    try {
      final message = await PdfSystemOpen.open(bytes, widget.fileName);
      if (!mounted) return;
      if (message != null && message != 'done') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _openingPdf = false);
    }
  }
}

class InlineFilePreview extends StatelessWidget {
  final FilePreviewData preview;
  final PdfControllerPinch? pdfController;

  const InlineFilePreview({
    required this.preview,
    this.pdfController,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface.withValues(alpha: 0.35);
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
        _ => const SizedBox.shrink(),
      },
    );
  }

  Widget _textSnippet(TextPreviewData? data, BuildContext context) {
    final lines = data?.lines ?? [];
    if (lines.isEmpty) {
      return Text('…', style: TextStyle(color: Theme.of(context).hintColor));
    }
    return Text(
      lines.join('\n'),
      maxLines: ReadableFilePolicy.textSnippetLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 11,
        color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.9),
      ),
    );
  }

  Widget _sheetSnippet(SpreadsheetPreviewData? data, BuildContext context) {
    final rows = data?.rows ?? [];
    if (rows.isEmpty) {
      return Text('Spreadsheet', style: TextStyle(color: Theme.of(context).hintColor));
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
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimary
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
    return Row(
      children: [
        Icon(
          Icons.picture_as_pdf,
          size: 28,
          color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.9),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'PDF document',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.9),
            ),
          ),
        ),
      ],
    );
  }
}
