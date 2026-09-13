/// The 60 s sweeper must not write at idle: with nothing expired it only
/// scans memory and re-reads `tokens.json`, so the disk sees no rewrites and
/// no temp files. A rewrite every minute would wear an SD card for nothing.
library;

import 'dart:io';

import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:test/test.dart';

const _owner =
    '2222222222222222222222222222222222222222222222222222222222222222';

String _deposit(int seed) =>
    List.generate(32, (i) => ((seed + i) % 256).toRadixString(16).padLeft(2, '0'))
        .join();

/// One regular file: mtime plus full bytes. Content comparison subsumes the
/// inode check (Dart's FileStat exposes no inode): a rewrite via temp file +
/// rename always changes both bytes-or-mtime, and usually the inode too.
class _Snap {
  _Snap(this.modified, this.bytes);
  final DateTime modified;
  final List<int> bytes;
}

Map<String, _Snap> _snapshot(Directory root) {
  final out = <String, _Snap>{};
  for (final e in root.listSync(recursive: true)) {
    if (e is File) {
      out[e.path] = _Snap(e.statSync().modified, e.readAsBytesSync());
    }
  }
  return out;
}

List<String> _tmpFiles(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .map((e) => e.path)
    .where((p) => p.endsWith('.tmp'))
    .toList();

Future<RelayStore> _storeWithItem({
  required Directory dir,
  required int storedAt,
  required int expiresAt,
  required int tokenTtlHours,
  required int nowMs,
}) async {
  final store = await RelayStore.open(dir.path);
  await store.putTenant(_owner, <String, dynamic>{}, const [], const []);
  await store.putMailbox(_owner, _deposit(1), MailboxPolicy());
  await store.putItem(
    _owner,
    StoredItem(
      itemId: 'item-1',
      deposit: _deposit(1),
      storedAt: storedAt,
      expiresAt: expiresAt,
      size: 5,
      payload: const {'m': 'hi'},
    ),
  );
  store.addToken(ttlHours: tokenTtlHours, nowMs: nowMs);
  await store.saveTokens();
  return store;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('relay-sweeper-idle-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('three idle sweeps rewrite nothing and drop nothing', () async {
    const nowMs = 1000000;
    final store = await _storeWithItem(
      dir: dir,
      storedAt: nowMs - 1000,
      expiresAt: nowMs + 60000,
      tokenTtlHours: 1,
      nowMs: nowMs,
    );

    final before = _snapshot(dir);
    expect(_tmpFiles(dir), isEmpty);
    expect(before.keys, isNotEmpty);

    for (var i = 0; i < 3; i++) {
      final result = await sweepStore(store, nowMs: nowMs);
      expect(result.expiredItems, 0);
      expect(result.droppedTokens, 0);
    }

    expect(_tmpFiles(dir), isEmpty);
    final after = _snapshot(dir);
    final fresh = after.keys.toSet().difference(before.keys.toSet());
    // The token file lock is created once by the first sweep and reused
    // after: lock infrastructure, not a data write. Anything else is a
    // regression.
    expect(fresh, everyElement(endsWith('.lock')), reason: '$fresh');
    for (final entry in before.entries) {
      final now = after[entry.key];
      expect(now, isNotNull, reason: '${entry.key} disappeared');
      expect(now!.modified, entry.value.modified,
          reason: '${entry.key} was rewritten');
      expect(now.bytes, entry.value.bytes, reason: '${entry.key} changed');
    }
  });

  test('an expired item deletes exactly its file, tokens.json untouched',
      () async {
    const nowMs = 1000000;
    final store = await _storeWithItem(
      dir: dir,
      storedAt: nowMs - 2000,
      expiresAt: nowMs - 1,
      tokenTtlHours: 1,
      nowMs: nowMs,
    );

    final tokensFile = File('${dir.path}/tokens.json');
    final tokensBytes = tokensFile.readAsBytesSync();
    final tokensModified = tokensFile.statSync().modified;
    final itemPath =
        '${dir.path}/tenants/$_owner/mailboxes/${_deposit(1)}/items/item-1.json';
    expect(File(itemPath).existsSync(), isTrue);

    final result = await sweepStore(store, nowMs: nowMs);
    expect(result.expiredItems, 1);
    expect(result.droppedTokens, 0);

    expect(File(itemPath).existsSync(), isFalse);
    expect(store.tenants[_owner]!.items, isEmpty);
    expect(tokensFile.readAsBytesSync(), tokensBytes);
    expect(tokensFile.statSync().modified, tokensModified);
    expect(store.findToken(store.tokens.single.token), isNotNull);
    expect(_tmpFiles(dir), isEmpty);
  });
}
