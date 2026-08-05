// L3 end-to-end verification harness — real Tor, real onions, real server.
//
// This file boots the PRODUCTION inbound stack (PrysmServer +
// InboundMessageRouter + the three SQLCipher databases + a real Tor daemon
// with a real hidden service) inside `flutter test`, with no GUI —
// flutter_tester needs no display. A second Tor daemon plus a ~50-line
// hostile HTTP server plays the attacker. Attacker and victim talk
// exclusively over the real Tor network.
//
// Gated behind PRYSM_E2E=1 so CI (which runs plain `flutter test`) skips it.
// Designed to run inside the isolated container built by .l3e2e/run.sh:
// TorManager's cleanup can `pkill -9 tor` without a pattern
// (lib/util/tor_service.dart:488-505) — the container's PID namespace is
// what makes that safe.
//
// Experiment M2 (docs/security-scan-verification.md): on message receipt the
// victim used to issue GET /profile to the sender — an implicit delivery
// confirmation. L2 can show the call site; only L3 shows the actual HTTP hit
// landing on the attacker's access log through real Tor. The fix (Task 5 +
// final review) moved the fetch behind authentication; this test is now a
// REGRESSION GUARD: it proves the oracle stays closed while the attacker
// remains provably reachable (preflight probe visible in the hostile log).

@Timeout(Duration(minutes: 40))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/sqflite_platform.dart';
import 'package:prysm/util/tor_service.dart';

final _enabled = Platform.environment['PRYSM_E2E'] == '1';

/// Polls [check] every [interval] until it returns non-null or [timeout]
/// elapses. Returns null on timeout.
Future<T?> _poll<T>(
  FutureOr<T?> Function() check, {
  required Duration timeout,
  Duration interval = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = await check();
    if (value != null) return value;
    await Future.delayed(interval);
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'L3 headless E2E (real Tor)',
    skip: _enabled
        ? false
        : 'set PRYSM_E2E=1 and run inside .l3e2e/run.sh (isolated container)',
    () {
      late Directory workDir;
      late Directory attackerDir;
      late PrysmServer server;
      late TorManager victimTor;
      late String victimOnion;

      Process? attackerTor;
      HttpServer? hostileServer;
      String? attackerOnion;
      final hostileLog = <String>[];

      setUpAll(() async {
        workDir = Directory.systemTemp.createTempSync('prysm_l3e2e_victim');
        attackerDir = Directory.systemTemp.createTempSync('prysm_l3e2e_attacker');

        // --- Victim boot chain (L3 feasibility study, verdict 1) ---

        // FFI sqflite → SQLCipher via package:sqlite3 (production opener).
        ensureSqflitePlatformInitialized();

        // path_provider → per-run temp dir; the three production DB openers
        // resolve their files from here.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationDocumentsDirectory' ||
                call.method == 'getTemporaryDirectory') {
              return workDir.path;
            }
            return null;
          },
        );

        // H6 fail-loudly: without this, opening any DB throws because
        // flutter_secure_storage has no handler under flutter_test.
        CryptoKeyStore.setUseInMemoryStorageOnly(true);

        // TestWidgetsFlutterBinding.ensureInitialized() builds an
        // AutomatedTestWidgetsFlutterBinding, which installs a mock
        // HttpOverrides answering every HttpClient request instantly with
        // an empty 400 body. That silently neuters the victim's outbound
        // profile fetch — the very behavior under test (symptom:
        // FormatException "Unexpected end of input" ~3ms after each
        // message). Restore the real client for this experiment.
        HttpOverrides.global = null;

        // Identity + production server on the production port.
        final identity = await IdentityKeyPair.generate();
        final keyManager = KeyManager.fromIdentity(identity);
        server = PrysmServer(port: 12345, keyManager: keyManager);
        await server.start();

        // Victim Tor — DIRECT construction (no path_provider, no
        // TorDownloader). SOCKS stays on the default 9050 because
        // PrysmServer._fetchSenderProfile hardcodes it
        // (lib/server/PrysmServer.dart:350-353).
        final torBin = File('tor_executable/tor').absolute.path;
        final controlPassword = await CryptoKeyStore.torControlPassword();
        victimTor = TorManager(
          torPath: torBin,
          dataDir: '${workDir.path}/tor_data',
          controlPassword: controlPassword,
        );
        // startTor includes bootstrap wait (up to 2 min). It also runs the
        // orphan cleanup with the broad `pkill -9 tor` fallback — safe here
        // only because the attacker tor does not exist YET. Order matters:
        // the attacker daemon MUST be spawned after this line, and the
        // victim tor must never be restarted while the attacker runs.
        await victimTor.startTor();

        final foundVictimOnion = await _poll(
          () => victimTor.getOnionAddress(),
          timeout: const Duration(minutes: 2),
        );
        if (foundVictimOnion == null) {
          fail('victim onion never appeared');
        }
        victimOnion = foundVictimOnion;
        server.localOnionAddress = victimOnion;

        // --- Attacker: own tor daemon + hostile /profile server ---

        final hostilePort = 18080;
        hostileServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          hostilePort,
        );
        final attackerIdentity = await IdentityKeyPair.generate();
        final profileJson = jsonEncode({
          'identityJson': jsonEncode(await attackerIdentity.toPublicJson()),
          'publicKeyPem': jsonEncode(await attackerIdentity.toPublicJson()),
          'username': 'l3e2e-attacker',
          'avatar': '',
        });
        hostileServer!.listen((request) {
          hostileLog.add(
            '${DateTime.now().toIso8601String()} '
            '${request.method} ${request.uri}',
          );
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(profileJson)
            ..close();
        });

        // Attacker tor: minimal torrc (no ControlPort — nothing controls
        // this daemon, and a malformed HashedControlPassword makes tor
        // reject the whole config), dedicated SOCKS port, own hidden
        // service pointing at the hostile server.
        final attackerTorrc = File('${attackerDir.path}/torrc');
        attackerTorrc.writeAsStringSync('''
SocksPort 19150
DataDirectory ${attackerDir.path}/data
HiddenServiceDir ${attackerDir.path}/hs/
HiddenServicePort 80 127.0.0.1:$hostilePort
''');
        Directory('${attackerDir.path}/data').createSync(recursive: true);
        Directory('${attackerDir.path}/hs').createSync(recursive: true);
        // Tor refuses a hidden-service dir with group/other permissions.
        Process.runSync('chmod', ['700', '${attackerDir.path}/hs']);

        attackerTor = await Process.start(torBin, ['-f', attackerTorrc.path]);
        // Keep the daemon's log for post-mortem: on a config error tor
        // prints it and exits, and without this we would be blind.
        final attackerTorLog = <String>[];
        attackerTor!.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(attackerTorLog.add);
        attackerTor!.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(attackerTorLog.add);

        final foundAttackerOnion = await _poll(
          () {
            final f = File('${attackerDir.path}/hs/hostname');
            return f.existsSync() && f.readAsStringSync().trim().isNotEmpty
                ? f.readAsStringSync().trim()
                : null;
          },
          timeout: const Duration(minutes: 3),
        );
        if (foundAttackerOnion == null) {
          fail(
            'attacker hidden service hostname never appeared.\n'
            'attacker tor log (last 25 lines):\n'
            '${attackerTorLog.length <= 25 ? attackerTorLog.join('\n') : attackerTorLog.sublist(attackerTorLog.length - 25).join('\n')}',
          );
        }
        attackerOnion = foundAttackerOnion;

        // Give the attacker's hidden service time to publish its descriptor
        // before the victim tries to reach it.
        await Future.delayed(const Duration(seconds: 30));
      });

      tearDownAll(() async {
        attackerTor?.kill();
        hostileServer?.close(force: true);
        try {
          await victimTor.stopTor().timeout(const Duration(seconds: 20));
        } catch (_) {
          // Container teardown kills leftovers anyway.
        }
        try {
          await server.stop();
        } catch (_) {}
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        CryptoKeyStore.setUseInMemoryStorageOnly(false);
        if (workDir.existsSync()) workDir.deleteSync(recursive: true);
        if (attackerDir.existsSync()) attackerDir.deleteSync(recursive: true);
      });

      test(
        'M2 regression: receiving an undecryptable message does not leak a '
        'delivery confirmation via GET /profile',
        () async {
          // Pre-flight: can the VICTIM's tor reach the attacker onion at
          // all? This both diagnoses tor-level reachability (status, body
          // size, wall time) and warms the victim tor's descriptor cache
          // for the attacker onion, so the subsequent message POSTs do not
          // race hidden-service descriptor propagation. The probe is
          // tagged requester=preflight-probe so it stays distinguishable
          // from the victim's own fetch (requester=<victim onion>).
          final preflight = await Process.run(
            'curl',
            [
              '--socks5-hostname',
              '127.0.0.1:9050',
              '-sS',
              '-m',
              '180',
              '-o',
              '-',
              '-w',
              '\nPREFLIGHT HTTP %{http_code} %{size_download}B %{time_total}s',
              'http://$attackerOnion/profile?requester=preflight-probe',
            ],
          );
          // ignore: avoid_print
          print(
            'PREFLIGHT via victim socks: exit=${preflight.exitCode}\n'
            '${preflight.stdout}\n${preflight.stderr}',
          );

          // Negative control: the victim's own onion must not appear as
          // requester before any message is received.
          expect(
            hostileLog.where((l) => l.contains('requester=$victimOnion')),
            isEmpty,
            reason: 'precondition: no profile fetch before the message',
          );

          // The envelope is intentionally not decryptable: pre-fix, the
          // oracle fired BEFORE authentication (inbound_message_router.dart
          // fetched the sender profile before DirectMessageAuth), so a 400
          // reply still leaked. The fix moved the fetch behind
          // authentication; each POST below must now be answered WITHOUT any
          // outbound GET /profile. Retry through tor's hidden-service
          // rendezvous window instead of assuming the circuit works on the
          // first try.
          String? hit;
          for (var attempt = 1; attempt <= 8 && hit == null; attempt++) {
            final body = jsonEncode({
              'id': 'm2-l3e2e-$attempt',
              'senderId': attackerOnion,
              'receiverId': victimOnion,
              'message': 'not-a-valid-envelope',
              'type': 'text',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            });
            final post = await Process.run(
              'curl',
              [
                '--socks5-hostname',
                '127.0.0.1:19150',
                '-sS',
                '-m',
                '120',
                '-o',
                '-',
                '-w',
                '\nHTTP %{http_code}',
                '-X',
                'POST',
                'http://$victimOnion/message',
                '-H',
                'Content-Type: application/json',
                '-d',
                body,
              ],
            );
            expect(
              post.exitCode,
              0,
              reason: 'curl transport failed: ${post.stderr}',
            );

            // Watch window: IF the leak regresses, the victim's fetch lands
            // in the attacker's access log within the Tor round-trip
            // budget, carrying the victim's own onion as ?requester= —
            // proof that the victim is online AND processed the message.
            // The loop polls for this oracle so a regression is caught
            // while the absence of the oracle stays the expected outcome.
            hit = await _poll(
              () {
                for (final line in hostileLog) {
                  if (line.contains('GET /profile') &&
                      line.contains('requester=$victimOnion')) {
                    return line;
                  }
                }
                return null;
              },
              timeout: const Duration(seconds: 30),
            );
          }

          // The preflight probe must still be visible in the hostile log:
          // it proves the attacker was reachable from the victim's tor, so
          // an absent oracle is a fixed leak, not a false negative caused
          // by an unreachable attacker.
          expect(
            hostileLog.where((l) => l.contains('requester=preflight-probe')),
            isNotEmpty,
            reason: 'precondition failed: the preflight probe never reached '
                'the attacker — the harness cannot tell a fixed leak from '
                'an unreachable attacker. Hostile log:\n'
                '${hostileLog.join('\n')}',
          );

          expect(
            hit,
            isNull,
            reason: 'M2 regression: the victim fetched the attacker profile '
                'after 8 messages, leaking a delivery confirmation '
                '(requester=<victim onion>). Hostile log:\n'
                '${hostileLog.join('\n')}',
          );
        },
      );
    },
  );
}
