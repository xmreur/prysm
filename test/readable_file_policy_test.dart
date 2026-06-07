import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/readable_file_policy.dart';

void main() {
  test('categorizes text and pdf extensions', () {
    expect(ReadableFilePolicy.categorize('notes.txt'), FilePreviewCategory.text);
    expect(ReadableFilePolicy.categorize('doc.pdf'), FilePreviewCategory.pdf);
    expect(ReadableFilePolicy.categorize('sheet.xlsx'),
        FilePreviewCategory.spreadsheet);
    expect(ReadableFilePolicy.categorize('report.docx'),
        FilePreviewCategory.document);
  });

  test('blocks executable extensions', () {
    expect(ReadableFilePolicy.categorize('setup.exe'),
        FilePreviewCategory.blocked);
    expect(ReadableFilePolicy.categorize('run.sh'), FilePreviewCategory.blocked);
    expect(
      ReadableFilePolicy.requiresDownloadWarning(
        ReadableFilePolicy.categorize('virus.exe'),
      ),
      isTrue,
    );
  });

  test('legacy xls is binary not spreadsheet preview', () {
    expect(ReadableFilePolicy.categorize('old.xls'), FilePreviewCategory.binary);
    expect(
      ReadableFilePolicy.supportsInlinePreview(FilePreviewCategory.binary),
      isFalse,
    );
  });

  test('unknown extension is binary', () {
    expect(ReadableFilePolicy.categorize('archive.zip'),
        FilePreviewCategory.binary);
  });

  test('exceedsPreviewLimit above 10 MB', () {
    expect(
      ReadableFilePolicy.exceedsPreviewLimit(10 * 1024 * 1024),
      isFalse,
    );
    expect(
      ReadableFilePolicy.exceedsPreviewLimit(10 * 1024 * 1024 + 1),
      isTrue,
    );
  });
}
