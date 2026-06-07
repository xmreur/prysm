import 'dart:convert';
import 'dart:typed_data';

import 'package:docx_to_text/docx_to_text.dart';
import 'package:excel/excel.dart';
import 'package:pdfx/pdfx.dart';
import 'package:prysm/util/readable_file_policy.dart';

class TextPreviewData {
  final List<String> lines;
  final String fullText;

  const TextPreviewData({required this.lines, required this.fullText});
}

class SpreadsheetPreviewData {
  final List<List<String>> rows;

  const SpreadsheetPreviewData({required this.rows});
}

class PdfPreviewData {
  final Uint8List documentBytes;

  const PdfPreviewData({required this.documentBytes});
}

class FilePreviewData {
  final FilePreviewCategory category;
  final TextPreviewData? text;
  final SpreadsheetPreviewData? spreadsheet;
  final PdfPreviewData? pdf;

  const FilePreviewData._({
    required this.category,
    this.text,
    this.spreadsheet,
    this.pdf,
  });

  factory FilePreviewData.blocked() => const FilePreviewData._(
        category: FilePreviewCategory.blocked,
      );

  factory FilePreviewData.binary() => const FilePreviewData._(
        category: FilePreviewCategory.binary,
      );

  factory FilePreviewData.text(TextPreviewData data) => FilePreviewData._(
        category: FilePreviewCategory.text,
        text: data,
      );

  factory FilePreviewData.spreadsheet(SpreadsheetPreviewData data) =>
      FilePreviewData._(
        category: FilePreviewCategory.spreadsheet,
        spreadsheet: data,
      );

  factory FilePreviewData.pdf(PdfPreviewData data) => FilePreviewData._(
        category: FilePreviewCategory.pdf,
        pdf: data,
      );
}

class FilePreviewService {
  FilePreviewService._();

  static Future<FilePreviewData> buildPreview({
    required String fileName,
    required Uint8List bytes,
    required bool inline,
  }) async {
    final category = ReadableFilePolicy.categorize(fileName);
    if (category == FilePreviewCategory.blocked) {
      return FilePreviewData.blocked();
    }
    if (!ReadableFilePolicy.supportsInlinePreview(category) && inline) {
      return FilePreviewData.binary();
    }
    if (bytes.isEmpty) {
      return FilePreviewData.binary();
    }

    final capped = bytes.length > ReadableFilePolicy.maxPreviewBytes
        ? Uint8List.fromList(bytes.sublist(0, ReadableFilePolicy.maxPreviewBytes))
        : bytes;

    return switch (category) {
      FilePreviewCategory.text => FilePreviewData.text(
          _buildTextPreview(capped, inline: inline),
        ),
      FilePreviewCategory.document => FilePreviewData.text(
          _buildDocxPreview(capped, inline: inline),
        ),
      FilePreviewCategory.spreadsheet => FilePreviewData.spreadsheet(
          _buildSpreadsheetPreview(capped, inline: inline),
        ),
      FilePreviewCategory.pdf => FilePreviewData.pdf(
          PdfPreviewData(documentBytes: capped),
        ),
      _ => FilePreviewData.binary(),
    };
  }

  static TextPreviewData _buildTextPreview(
    Uint8List bytes, {
    required bool inline,
  }) {
    final sample = bytes.length > ReadableFilePolicy.textSnippetBytes
        ? bytes.sublist(0, ReadableFilePolicy.textSnippetBytes)
        : bytes;
    final fullText = utf8.decode(sample, allowMalformed: true);
    final allLines = const LineSplitter().convert(fullText);
    final maxLines = inline
        ? ReadableFilePolicy.textSnippetLines
        : allLines.length;
    final lines = allLines.take(maxLines).toList();
    return TextPreviewData(lines: lines, fullText: fullText);
  }

  static TextPreviewData _buildDocxPreview(
    Uint8List bytes, {
    required bool inline,
  }) {
    try {
      final fullText = docxToText(bytes);
      final allLines = const LineSplitter().convert(fullText);
      final maxLines = inline
          ? ReadableFilePolicy.textSnippetLines
          : allLines.length;
      final lines = allLines.take(maxLines).toList();
      return TextPreviewData(lines: lines, fullText: fullText);
    } catch (_) {
      return const TextPreviewData(lines: ['Could not read document'], fullText: '');
    }
  }

  static SpreadsheetPreviewData _buildSpreadsheetPreview(
    Uint8List bytes, {
    required bool inline,
  }) {
    try {
      final book = Excel.decodeBytes(bytes);
      if (book.tables.isEmpty) {
        return const SpreadsheetPreviewData(rows: []);
      }
      final sheet = book.tables.values.first;
      final maxRows = inline
          ? ReadableFilePolicy.spreadsheetBubbleRows
          : ReadableFilePolicy.spreadsheetFullMaxRows;
      final maxCols = inline
          ? ReadableFilePolicy.spreadsheetBubbleCols
          : sheet.maxColumns;

      final rows = <List<String>>[];
      for (var r = 0; r < maxRows && r < sheet.maxRows; r++) {
        final row = <String>[];
        for (var c = 0; c < maxCols; c++) {
          final cell = sheet.cell(
            CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
          );
          row.add(cell.value?.toString() ?? '');
        }
        rows.add(row);
      }
      return SpreadsheetPreviewData(rows: rows);
    } catch (_) {
      return const SpreadsheetPreviewData(rows: []);
    }
  }

  static Future<bool> isPdfRenderingSupported() => hasPdfSupport();

  static Future<PdfControllerPinch?> openPdfController(Uint8List bytes) async {
    if (!await hasPdfSupport()) return null;
    try {
      final doc = await PdfDocument.openData(bytes);
      return PdfControllerPinch(document: Future.value(doc));
    } catch (_) {
      return null;
    }
  }
}
