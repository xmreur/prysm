import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/lyrebird_locator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LyrebirdLocator asset keys', () {
    test('linuxAssetArch maps arm64 variants', () {
      expect(LyrebirdLocator.linuxAssetArch(), isIn(['amd64', 'arm64']));
    });
  });

  group('LyrebirdLocator bundled paths', () {
    test('candidateBundledPaths is non-empty on desktop test host', () {
      final paths = LyrebirdLocator.candidateBundledPaths();
      expect(paths, isNotEmpty);
      for (final p in paths) {
        expect(p, contains('lyrebird'));
      }
    });
  });

  group('LyrebirdLocator asset extraction', () {
    test('throws when asset is missing', () async {
      final locator = LyrebirdLocator(
        assetBundle: _EmptyAssetBundle(),
        applicationSupportDirectory: () async => Directory.systemTemp,
      );

      await expectLater(
        locator.resolveLyrebirdPath(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            LyrebirdLocator.bundledMissingMessage,
          ),
        ),
      );
    });

    test('extracts asset bytes to support directory', () async {
      final tempDir = await Directory.systemTemp.createTemp('lyrebird_locator_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final locator = LyrebirdLocator(
        assetBundle: _FakeAssetBundle([1, 2, 3, 4]),
        applicationSupportDirectory: () async => tempDir,
      );

      final path = await locator.resolveLyrebirdPath();
      expect(await File(path).exists(), isTrue);
      expect(await File(path).length(), 4);
    });
  });
}

class _EmptyAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('asset not found: $key');
  }
}

class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this.bytes);

  final List<int> bytes;

  @override
  Future<ByteData> load(String key) async {
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}
