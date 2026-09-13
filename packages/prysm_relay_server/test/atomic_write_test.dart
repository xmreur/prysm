/// Every store write is write-to-temp + `rename`. Two writers of the same file
/// must not share a temp name: that is not an atomic write, it is a race.
library;

import 'dart:convert';
import 'dart:io';

import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:test/test.dart';

String _deposit(int seed) =>
    List.generate(32, (i) => ((seed + i) % 256).toRadixString(16).padLeft(2, '0'))
        .join();

const _owner =
    '1111111111111111111111111111111111111111111111111111111111111111';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('relay-atomic-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('concurrent index writes all succeed and leave no temp files',
      () async {
    final store = await RelayStore.open(dir.path);
    await store.putTenant(_owner, <String, dynamic>{}, const [], const []);

    // Every `putMailbox` rewrites `index.json`; ten at once used to kill all
    // but the first with PathNotFoundException on the shared `.tmp`.
    await Future.wait([
      for (var i = 0; i < 10; i++)
        store.putMailbox(_owner, _deposit(i), MailboxPolicy()),
    ]);

    expect(store.depositIndex, hasLength(10));
    final onDisk = jsonDecode(
      File('${dir.path}/index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(onDisk.values, everyElement(_owner));
    expect(
      dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('two processes opening the same data dir both succeed', () async {
    await RelayStore.open(dir.path);
    final opened = await Future.wait([
      for (var i = 0; i < 4; i++) RelayStore.open(dir.path),
    ]);
    expect(opened, hasLength(4));
    expect(
      RelayFields.fingerprint(_owner, field: 'ownerFingerprint'),
      _owner,
    );
  });
}
