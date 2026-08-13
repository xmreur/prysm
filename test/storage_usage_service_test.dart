import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/storage_usage_service.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('prysm_storage_test_');
    await SettingsService().setCustomDownloadPath(tempRoot.path);
  });

  tearDown(() async {
    await SettingsService().clearCustomDownloadPath();
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

  test('listDownloadedFiles excludes backup files and sorts by size desc', () async {
    await File('${tempRoot.path}/small.txt').writeAsString('0123456789');
    await File('${tempRoot.path}/large.zip').writeAsString('z' * 1000);
    await File('${tempRoot.path}/backup.prysmbackup').writeAsString('b' * 500);
    await File('${tempRoot.path}/nested.txt').writeAsString('x');
    await Directory('${tempRoot.path}/sub').create();

    final entries = await StorageUsageService.listDownloadedFiles();

    expect(entries.map((e) => e.name), ['large.zip', 'small.txt', 'nested.txt']);
    expect(entries.map((e) => e.name), isNot(contains('backup.prysmbackup')));
    expect(entries.map((e) => e.bytes), [1000, 10, 1]);
  });
}
