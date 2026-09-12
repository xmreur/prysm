/// Live end-to-end smoke driver: manifest -> pair -> mailbox put -> deposit
/// (sealed) -> pickup -> ack -> status -> unpair. Prints every JSON response.
///
/// Run against a relay started with `serve`:
/// `dart run tool/e2e.dart --relay http://127.0.0.1:8443 --token <hex>`
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

Future<void> main(List<String> args) async {
  var relay = 'http://127.0.0.1:8443';
  var token = '';
  var ownerOnion =
      'x55eyojvaadl75tsz5s4ee7zu6ckq6cifrhzrlcuu7my72rxeqrz5ead.onion';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--relay' && i + 1 < args.length) relay = args[++i];
    if (args[i] == '--token' && i + 1 < args.length) token = args[++i];
    if (args[i] == '--owner-onion' && i + 1 < args.length) {
      ownerOnion = args[++i];
    }
  }
  if (token.isEmpty) {
    stderr.writeln('usage: dart run tool/e2e.dart --token <hex> [--relay url]');
    exit(2);
  }
  // This driver posts a single-use setup token in cleartext and speaks plain
  // HTTP (no SOCKS), so the only address it can reach safely is the relay's
  // own loopback listener. Anything else would hand the token to the network.
  final relayUri = Uri.tryParse(relay);
  if (relayUri == null || !_isLoopbackUrl(relayUri)) {
    stderr.writeln(
      'refusing --relay "$relay": this tool sends a setup token in cleartext, '
      'so it only talks to a loopback relay (http://127.0.0.1:<port>). '
      'Reach a remote relay through an SSH tunnel or torsocks instead.',
    );
    exit(2);
  }
  final ed = Ed25519();
  final sign = await ed.newKeyPair();
  final agree = await X25519().newKeyPair();
  final signPub = (await sign.extractPublicKey()).bytes;
  final agreePub = (await agree.extractPublicKey()).bytes;
  final owner =
      RelayIdentity.fromKeys(signPublic: signPub, agreePublic: agreePub);

  Future<Map<String, dynamic>> show(String label, http.Response r) async {
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    // ignore: avoid_print
    print('### $label -> ${r.statusCode}\n${const JsonEncoder.withIndent('  ').convert(body)}\n');
    return body;
  }

  Future<Map<String, String>> auth(
    String method,
    String path,
    String body,
    String relayFpr,
  ) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await RelaySigning.sign(
      RelaySigning.authBytes(
        relayFingerprint: relayFpr,
        ownerFingerprint: owner.fingerprint,
        method: method,
        path: path,
        timestampMs: ts,
        bodySha256Hex: RelaySigning.sha256Hex(utf8.encode(body)),
      ),
      sign,
    );
    return {
      RelayProtocol.headerOwner: owner.fingerprint,
      RelayProtocol.headerTimestamp: '$ts',
      RelayProtocol.headerSignature: sig,
      'content-type': 'application/json',
    };
  }

  void check(bool ok, String what) {
    if (!ok) {
      stderr.writeln('E2E FAILED: $what');
      exit(1);
    }
  }

  // 1. manifest (public, self-verifying).
  final manifestRes =
      await http.get(Uri.parse('$relay${RelayProtocol.pathManifest}'));
  final manifestBody = await show('GET manifest', manifestRes);
  final manifest = RelayManifest.fromJson(manifestBody);
  check(await manifest.verifySelf(), 'manifest self-verification');
  final relayFpr = manifest.relayFingerprint;

  // 2. pair.
  final pairTs = DateTime.now().millisecondsSinceEpoch;
  final pairSig = await RelaySigning.sign(
    RelaySigning.pairBytes(
      relayFingerprint: relayFpr,
      ownerFingerprint: owner.fingerprint,
      token: token,
      timestampMs: pairTs,
    ),
    sign,
  );
  final pairRes = await http.post(
    Uri.parse('$relay${RelayProtocol.pathPair}'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'protocol': RelayProtocol.id,
      'token': token,
      'ownerIdentityJson': owner.toJsonString(),
      'ownerOnion': ownerOnion,
      'requested': <String, dynamic>{},
      'timestamp': pairTs,
      'sig': pairSig,
    }),
  );
  final contractBody = await show('POST pair', pairRes);
  check(pairRes.statusCode == 200, 'pair status');
  final contract = RelayContract.fromJson(contractBody);
  check(await contract.verify(signPubOf(manifest)), 'contract signature');

  // 3. mailbox put.
  final deposit = RelaySeal.randomBytes(32)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  Future<http.Response> authed(
    String path,
    Map<String, dynamic> body,
  ) async {
    final raw = jsonEncode(body);
    return http.post(
      Uri.parse('$relay$path'),
      headers: await auth('POST', path, raw, relayFpr),
      body: raw,
    );
  }

  final putRes = await authed(RelayProtocol.pathMailbox, {
    'protocol': RelayProtocol.id,
    'op': 'put',
    'deposit': deposit,
    'label': 'smoke',
  });
  await show('POST mailbox put', putRes);
  check(putRes.statusCode == 200, 'mailbox put status');

  // 4. deposit a sealed envelope.
  final envelope = {'id': 'm1', 'text': 'hello via relay'};
  final sealed = await RelaySeal.seal(utf8.encode(jsonEncode(envelope)), agreePub);
  final depRes = await http.post(
    Uri.parse('$relay${RelayProtocol.pathDeposit}'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'protocol': RelayProtocol.id,
      'deposit': deposit,
      'payload': sealed,
    }),
  );
  final depBody = await show('POST deposit', depRes);
  check(depRes.statusCode == 200, 'deposit status');
  final itemId = depBody['itemId'] as String;

  // 5. pickup: payload must come back identical.
  final pickRes = await authed(
    RelayProtocol.pathPickup,
    {'protocol': RelayProtocol.id},
  );
  final pickBody = await show('POST pickup', pickRes);
  check(pickRes.statusCode == 200, 'pickup status');
  final items = pickBody['items'] as List;
  check(items.length == 1, 'one item picked up');
  check(
    canonicalJson((items.single as Map)['payload']) == canonicalJson(sealed),
    'payload byte-identical',
  );

  // 6. ack.
  final ackRes = await authed(RelayProtocol.pathAck, {
    'protocol': RelayProtocol.id,
    'itemIds': [itemId],
  });
  final ackBody = await show('POST ack', ackRes);
  check(ackBody['deleted'] == 1 && ackBody['unknown'] == 0, 'ack counts');

  // 7. status.
  final statusRes = await authed(
    RelayProtocol.pathStatus,
    {'protocol': RelayProtocol.id},
  );
  await show('POST status', statusRes);
  check(statusRes.statusCode == 200, 'status status');

  // 8. unpair.
  final unpairRes = await authed(RelayProtocol.pathUnpair, {'confirm': true});
  final unpairBody = await show('POST unpair', unpairRes);
  check(
    unpairBody['status'] == 'unpaired' && unpairBody['deletedItems'] == 0,
    'unpair result',
  );

  // ignore: avoid_print
  print('E2E OK');
}

bool _isLoopbackUrl(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host;
  if (host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  return address != null && address.isLoopback;
}

List<int> signPubOf(RelayManifest manifest) =>
    manifest.identity.signPublic.toList();
