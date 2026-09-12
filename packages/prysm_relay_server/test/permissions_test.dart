/// The two paths that must never be readable by another account: the relay's
/// signing seeds and the data dir holding them and the bearer tokens.
library;

import 'dart:io';

import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:test/test.dart';

/// POSIX permission bits of [path].
int _mode(String path) => File(path).statSync().mode & 0x1FF;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('relay-perm-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('a failed chmod is an error, not a shrug', () async {
    await expectLater(
      restrictPath('${dir.path}/not-a-real-path', '600'),
      throwsA(isA<StateError>()),
    );
  }, testOn: '!windows');

  test('a generated identity is 0600 and the data dir 0700', () async {
    final store = await RelayStore.open('${dir.path}/data');
    await RelayKeyPair.generateAndSave(store.dataDir);

    expect(_mode(store.dataDir), 0x1C0); // 0700
    expect(_mode('${store.dataDir}/identity.json'), 0x180); // 0600
  }, testOn: '!windows');
}
