/// `tokens.json` is rewritten wholesale by everything that touches it, and
/// two processes routinely do: `token new` from a shell while `serve` holds the
/// list in memory.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('relay-token-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  List<String> tokensOnDisk() => [
        for (final e in jsonDecode(
          File('${dir.path}/tokens.json').readAsStringSync(),
        ) as List)
          (e as Map)['token'] as String,
      ];

  test('minting from a stale snapshot keeps the other writer\'s token',
      () async {
    final serving = await RelayStore.open(dir.path);
    final a = await serving.mintToken(ttlHours: 1, nowMs: 1000);

    // A second process mints while `serving` still holds its own snapshot.
    final cli = await RelayStore.open(dir.path);
    final b = await cli.mintToken(ttlHours: 1, nowMs: 1000);

    final c = await serving.mintToken(ttlHours: 1, nowMs: 1000);

    expect(tokensOnDisk(), containsAll([a.token, b.token, c.token]));
  });

  test('the sweeper does not drop a token minted by another process', () async {
    final serving = await RelayStore.open(dir.path);
    final cli = await RelayStore.open(dir.path);
    final fresh = await cli.mintToken(ttlHours: 1, nowMs: 1000);

    await serving.pruneTokens(2000);

    expect(tokensOnDisk(), contains(fresh.token));
    expect(serving.findToken(fresh.token), isNotNull);
  });

  test('the token lock also serialises two consumptions inside one process',
      () async {
    // Two `/pair` handlers inside one `serve`: a POSIX file lock is per
    // *process*, so a second `lock()` on the same file returns immediately and
    // both bodies used to run at once. Each writes `tokens.json` wholesale
    // from a snapshot, so two overlapping writes can rename the staler one
    // last and drop a `usedBy` - a single-use token reusable after a restart.
    final store = await RelayStore.open(dir.path);
    final a = await store.mintToken(ttlHours: 1, nowMs: 1000);
    final b = await store.mintToken(ttlHours: 1, nowMs: 1000);
    var inside = 0;
    var maxInside = 0;

    await Future.wait([
      for (final (token, owner) in [(a.token, 'ownerA'), (b.token, 'ownerB')])
        store.withTokenLock(() async {
          inside++;
          maxInside = inside > maxInside ? inside : maxInside;
          await store.reloadTokens();
          store.findToken(token)!.usedBy = owner;
          // The real pair handler signs and stores the tenant here, so the
          // snapshot `saveTokens` takes is far from the consumption above.
          await Future<void>.delayed(Duration.zero);
          await store.saveTokens();
          inside--;
        }),
    ]);

    expect(maxInside, 1, reason: 'the lock must exclude, not just advise');
    final reopened = await RelayStore.open(dir.path);
    expect(reopened.findToken(a.token)?.usedBy, 'ownerA');
    expect(reopened.findToken(b.token)?.usedBy, 'ownerB');
  });

  test('concurrent `token new` processes all land in the file', () async {
    // The cross-process guarantee, end to end: four CLIs minting at once.
    await RelayStore.open(dir.path);
    File('${dir.path}/config.json').writeAsStringSync(
      jsonEncode({
        'onion': '',
        'bind': '127.0.0.1',
        'port': 8443,
        'dataDir': dir.path,
      }),
    );
    final runs = await Future.wait([
      for (var i = 0; i < 4; i++)
        Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/prysm_relay.dart',
          'token',
          'new',
          '--config',
          '${dir.path}/config.json',
          '--ttl',
          '1',
        ]),
    ]);
    final minted = [
      for (final r in runs) (r.stdout as String).trim(),
    ];
    expect(runs.map((r) => r.exitCode), everyElement(0));
    expect(minted.toSet(), hasLength(4));
    expect(tokensOnDisk(), containsAll(minted));
  });
}
