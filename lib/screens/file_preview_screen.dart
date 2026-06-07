import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';
import 'package:prysm/screens/widgets/file_preview_content.dart';
import 'package:prysm/services/file_preview_service.dart';
import 'package:prysm/util/file_download_helper.dart';
import 'package:prysm/util/readable_file_policy.dart';

class FilePreviewScreen extends StatefulWidget {
  final String fileName;
  final int? fileSize;
  final Future<Uint8List> bytesFuture;
  final FilePreviewCategory category;

  const FilePreviewScreen({
    required this.fileName,
    required this.bytesFuture,
    required this.category,
    this.fileSize,
    super.key,
  });

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  FilePreviewData? _preview;
  Uint8List? _bytes;
  PdfControllerPinch? _pdfController;
  bool _loading = true;
  bool _tooLarge = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (widget.fileSize != null &&
          ReadableFilePolicy.exceedsPreviewLimit(widget.fileSize!)) {
        setState(() {
          _loading = false;
          _tooLarge = true;
        });
        return;
      }

      final bytes = await widget.bytesFuture;
      if (!mounted) return;
      if (bytes.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'File is still decrypting or empty';
          _preview = FilePreviewData.binary();
        });
        return;
      }

      if (ReadableFilePolicy.exceedsPreviewLimit(bytes.length)) {
        setState(() {
          _bytes = bytes;
          _loading = false;
          _tooLarge = true;
        });
        return;
      }

      final preview = await FilePreviewService.buildPreview(
        fileName: widget.fileName,
        bytes: bytes,
        inline: false,
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
        _preview = FilePreviewData.binary();
      });
    }
  }

  Future<void> _download() async {
    final bytes = _bytes ?? await widget.bytesFuture;
    if (!mounted || bytes.isEmpty) return;
    await FileDownloadHelper.download(
      context,
      fileName: widget.fileName,
      bytes: bytes,
      category: widget.category,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download',
            onPressed: _loading ? null : _download,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tooLarge
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.insert_drive_file, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          'File too large to preview',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${widget.fileName} exceeds the '
                          '${ReadableFilePolicy.maxPreviewBytes ~/ (1024 * 1024)} MB preview limit.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Theme.of(context).hintColor),
                        ),
                      ],
                    ),
                  ),
                )
              : _preview == null
              ? Center(child: Text(_error ?? 'Could not load preview'))
              : FilePreviewContent(
                  preview: _preview!,
                  fileName: widget.fileName,
                  pdfController: _pdfController,
                  bytes: _bytes,
                ),
    );
  }
}
