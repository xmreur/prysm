import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/storage_usage_service.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('prysm_storage_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('directorySizeForTest counts nested files', () async {
    final nested = Directory('${tempRoot.path}/nested');
    await nested.create(recursive: true);
    await File('${nested.path}/a.bin').writeAsBytes(List.filled(100, 0));
    await File('${nested.path}/b.bin').writeAsBytes(List.filled(50, 0));

    final size = await StorageUsageService.directorySizeForTest(nested);
    expect(size, 150);
  });

  test('listDownloadedFiles excludes backup files', () async {
    final entries = [
      DownloadedFileEntry(
        name: 'small.txt',
        path: '/tmp/small.txt',
        bytes: 10,
        modifiedAt: DateTime(2024),
      ),
      DownloadedFileEntry(
        name: 'large.zip',
        path: '/tmp/large.zip',
        bytes: 1000,
        modifiedAt: DateTime(2025),
      ),
    ]..sort((a, b) => b.bytes.compareTo(a.bytes));

    expect(entries.first.name, 'large.zip');
  });
}
