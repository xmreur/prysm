/// `pair-link` prints secrets, so it is tested through the real CLI: the
/// bug this covers is a wrong line (or a QR encoding anything but the
/// printed link), invisible to any in-process call.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:test/test.dart';

Future<ProcessResult> _cli(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/prysm_relay.dart', ...args],
    );

/// A data dir `pair-link` accepts: initialised, with a valid v3 onion.
Future<String> _readyDataDir(Directory parent) async {
  final dataDir = Directory('${parent.path}/data')..createSync();
  final init = await _cli(['init', '--data-dir', dataDir.path]);
  expect(init.exitCode, 0, reason: '${init.stderr}');
  final configFile = File('${dataDir.path}/config.json');
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  config['onion'] = '${'a' * 56}.onion';
  configFile.writeAsStringSync(jsonEncode(config));
  return dataDir.path;
}

List<String> _stdoutLines(ProcessResult r) =>
    (r.stdout as String).split('\n');

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('relay-pair-link-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('pair-link prints onion/fingerprint/token/link, then the QR', () async {
    final dataDir = await _readyDataDir(dir);
    final result =
        await _cli(['pair-link', '--config', '$dataDir/config.json']);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    final lines = _stdoutLines(result);
    expect(lines[0], startsWith('onion: '));
    expect(lines[1], startsWith('fingerprint: '));
    expect(lines[2], startsWith('token: '));
    expect(lines[3], startsWith('link: '));
    expect(lines[4], isEmpty);

    final onion = lines[0].substring('onion: '.length);
    final fingerprint = lines[1].substring('fingerprint: '.length);
    final token = lines[2].substring('token: '.length);
    final link = RelayPairingLink.parse(
      lines[3].substring('link: '.length),
    );
    expect(link.onion, onion);
    expect(link.fingerprint, fingerprint);
    expect(link.token, token);

    final readBack = await _cli(
      ['fingerprint', '--config', '$dataDir/config.json'],
    );
    expect(readBack.exitCode, 0, reason: '${readBack.stderr}');
    expect((readBack.stdout as String).trim(), fingerprint);

    final tokens = jsonDecode(
      File('$dataDir/tokens.json').readAsStringSync(),
    ) as List;
    expect(
      tokens.any((e) => (e as Map)['token'] == token),
      isTrue,
      reason: 'the linked token must be pending on the relay',
    );
  });

  test('--no-qr prints nothing after link:', () async {
    final dataDir = await _readyDataDir(dir);
    final result = await _cli(
      ['pair-link', '--config', '$dataDir/config.json', '--no-qr'],
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(_stdoutLines(result).where((l) => l.isNotEmpty), hasLength(4));
    expect(result.stdout, contains('link: prysm-relay://pair?'));
    expect(result.stdout, isNot(contains('█')));
  });

  test('--token reuses without minting; garbage exits 2', () async {
    final dataDir = await _readyDataDir(dir);
    final tokensFile = File('$dataDir/tokens.json');
    final before = tokensFile.readAsStringSync();
    final existing =
        ((jsonDecode(before) as List).single as Map)['token'] as String;

    final reused = await _cli([
      'pair-link',
      '--config',
      '$dataDir/config.json',
      '--token',
      existing,
    ]);
    expect(reused.exitCode, 0, reason: '${reused.stderr}');
    expect(
      RelayPairingLink.parse(
        _stdoutLines(reused)[3].substring('link: '.length),
      ).token,
      existing,
    );
    expect(tokensFile.readAsStringSync(), before);

    final bad = await _cli([
      'pair-link',
      '--config',
      '$dataDir/config.json',
      '--token',
      'not-hex',
    ]);
    expect(bad.exitCode, 2, reason: '${bad.stdout}${bad.stderr}');
  });

  test('the QR block is square with quiet zone and 4 glyphs', () async {
    final dataDir = await _readyDataDir(dir);
    final result =
        await _cli(['pair-link', '--config', '$dataDir/config.json']);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    final rows = _stdoutLines(result).skip(5).toList();
    if (rows.isNotEmpty && rows.last.isEmpty) rows.removeLast();
    expect(rows, isNotEmpty);

    // All four glyphs are BMP, so code units and code points agree.
    const glyphs = {' ', '▀', '▄', '█'};
    final widths = rows.map((r) => r.length).toSet();
    expect(widths, hasLength(1), reason: 'ragged QR rows');
    final size = widths.single;
    // Two module rows per text row, quiet zone of 2 modules: an odd square.
    expect(size.isOdd, isTrue);
    expect(rows.length, (size + 1) ~/ 2);
    for (final row in rows) {
      expect(row.split('').every(glyphs.contains), isTrue);
    }
  });
}
