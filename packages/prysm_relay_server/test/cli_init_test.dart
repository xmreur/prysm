/// `init` drives the filesystem, so it is tested through the real CLI: the
/// bug this covers was an ordering bug between two writes, invisible to any
/// in-process call.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _init(String dataDir) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/prysm_relay.dart', 'init', '--data-dir', dataDir],
    );

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('relay-cli-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('init refuses an existing config without minting an identity', () async {
    // The data dir an operator can realistically present: the config survived,
    // the identity did not (restored backup, wiped file, interrupted init).
    File('${dir.path}/config.json').writeAsStringSync('{}');

    final result = await _init(dir.path);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('config already exists'));
    expect(
      File('${dir.path}/identity.json').existsSync(),
      isFalse,
      reason: 'init must not create a relay identity it then refuses to use',
    );
  });

  test('init is idempotent-safe: a second run keeps the first identity',
      () async {
    final first = await _init(dir.path);
    expect(first.exitCode, 0, reason: '${first.stderr}');
    final identity = File('${dir.path}/identity.json').readAsStringSync();

    final second = await _init(dir.path);

    expect(second.exitCode, isNot(0));
    expect(File('${dir.path}/identity.json').readAsStringSync(), identity);
  });
}
