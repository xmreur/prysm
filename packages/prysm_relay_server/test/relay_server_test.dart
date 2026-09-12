/// End-to-end behaviour tests: the shelf handler is driven in-process (no
/// sockets) with a fake owner identity created via `cryptography`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _relayOnion =
    'k5cjn3lna3yaxx2hbgnofqln45dbythuj5d4ekzkf42jy3e6mkgst2yd.onion';
const _ownerOnion =
    'x55eyojvaadl75tsz5s4ee7zu6ckq6cifrhzrlcuu7my72rxeqrz5ead.onion';

RelayLimits _limits({
  int maxItemBytes = 64 * 1024,
  int maxMailboxItems = 256,
  int maxTenantBytes = 16 * 1024 * 1024,
  int itemTtlSeconds = 3600,
  int maxMailboxes = 16,
  int pickupBatchItems = 64,
  int pickupBatchBytes = 8 * 1024 * 1024,
}) =>
    RelayLimits(
      maxItemBytes: maxItemBytes,
      maxMailboxItems: maxMailboxItems,
      maxTenantBytes: maxTenantBytes,
      itemTtlSeconds: itemTtlSeconds,
      maxMailboxes: maxMailboxes,
      pickupBatchItems: pickupBatchItems,
      pickupBatchBytes: pickupBatchBytes,
    );

class _Harness {
  _Harness(this.server, this.dir, this.box);

  final RelayServer server;
  final Directory dir;
  final _Box box;

  int get nowMs => box.t;
  set nowMs(int value) => box.t = value;
}

class _Box {
  _Box(this.t);

  int t;

  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(t);
}

Future<_Harness> _server({
  RelayLimits? limits,
  RelayRateConfig? rate,
  RelayTenancy tenancy = RelayTenancy.private,
  RelayAdmission admission = RelayAdmission.invite,
  List<String> allowedOwners = const [],
}) async {
  final dir = await Directory.systemTemp.createTemp('relay-test-');
  // One data dir per case, so one removal per case: without this the suite
  // left a `/tmp/relay-test-*` directory behind for every test it ran.
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  final keys = await RelayKeyPair.generate();
  final box = _Box(DateTime.now().millisecondsSinceEpoch);
  final server = RelayServer(
    config: RelayConfig(
      onion: _relayOnion,
      bind: '127.0.0.1',
      port: 0,
      dataDir: dir.path,
      tenancy: tenancy,
      admission: admission,
      allowedOwners: allowedOwners,
      limits: limits ?? _limits(),
      rate: rate ?? const RelayRateConfig(),
      logLevel: 'counters',
      terms: '',
    ),
    keys: keys,
    store: await RelayStore.open(dir.path),
    log: RelayLog(debug: false),
    clock: box.clock,
  );
  return _Harness(server, dir, box);
}

/// A restart with an edited config: same identity and data dir, new policy.
/// This is how an operator revokes an owner - edit `config.json`, restart.
Future<_Harness> _restart(_Harness h, {List<String>? allowedOwners}) async {
  final old = h.server.config;
  return _Harness(
    RelayServer(
      config: RelayConfig(
        onion: old.onion,
        bind: old.bind,
        port: old.port,
        dataDir: old.dataDir,
        tenancy: old.tenancy,
        admission: old.admission,
        allowedOwners: allowedOwners ?? old.allowedOwners,
        limits: old.limits,
        rate: old.rate,
        logLevel: old.logLevel,
        terms: old.terms,
      ),
      keys: h.server.keys,
      store: await RelayStore.open(old.dataDir),
      log: RelayLog(debug: false),
      clock: h.box.clock,
    ),
    h.dir,
    h.box,
  );
}

class _Owner {
  _Owner({
    required this.sign,
    required this.signPublic,
    required this.agreePublic,
    required this.identity,
  });

  final SimpleKeyPair sign;
  final Uint8List signPublic;
  final Uint8List agreePublic;
  final RelayIdentity identity;

  String get fpr => identity.fingerprint;
  String get identityJson => identity.toJsonString();

  static Future<_Owner> create() async {
    final sign = await Ed25519().newKeyPair();
    final agree = await X25519().newKeyPair();
    final signPublic =
        Uint8List.fromList((await sign.extractPublicKey()).bytes);
    final agreePublic =
        Uint8List.fromList((await agree.extractPublicKey()).bytes);
    return _Owner(
      sign: sign,
      signPublic: signPublic,
      agreePublic: agreePublic,
      identity: RelayIdentity.fromKeys(
        signPublic: signPublic,
        agreePublic: agreePublic,
      ),
    );
  }

  Future<Map<String, dynamic>> pairBody(
    String relayFpr,
    String token, {
    Map<String, dynamic>? requested,
    int? timestampMs,
  }) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final sig = await RelaySigning.sign(
      RelaySigning.pairBytes(
        relayFingerprint: relayFpr,
        ownerFingerprint: fpr,
        token: token,
        timestampMs: ts,
      ),
      sign,
    );
    return {
      'protocol': RelayProtocol.id,
      'token': token,
      'ownerIdentityJson': identityJson,
      'ownerOnion': _ownerOnion,
      'requested': requested ?? {},
      'timestamp': ts,
      'sig': sig,
    };
  }

  Future<Map<String, String>> authHeaders({
    required String method,
    required String path,
    required String body,
    required String relayFpr,
    int? timestampMs,
  }) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final sig = await RelaySigning.sign(
      RelaySigning.authBytes(
        relayFingerprint: relayFpr,
        ownerFingerprint: fpr,
        method: method,
        path: path,
        timestampMs: ts,
        bodySha256Hex: RelaySigning.sha256Hex(utf8.encode(body)),
      ),
      sign,
    );
    return {
      RelayProtocol.headerOwner: fpr,
      RelayProtocol.headerTimestamp: '$ts',
      RelayProtocol.headerSignature: sig,
    };
  }
}

Future<({int status, Map<String, dynamic> body})> _post(
  RelayServer server,
  String path,
  Map<String, dynamic> body, {
  Map<String, String>? headers,
  int? timestampMs,
  _Owner? owner,
}) async {
  final bodyStr = jsonEncode(body);
  final hdrs = <String, String>{...?headers};
  if (owner != null) {
    hdrs.addAll(
      await owner.authHeaders(
        method: 'POST',
        path: path,
        body: bodyStr,
        relayFpr: server.keys.fingerprint,
        timestampMs: timestampMs,
      ),
    );
  }
  final resp = await server.handler(
    Request('POST', Uri.parse('http://relay$path'),
        body: bodyStr, headers: hdrs),
  );
  return (
    status: resp.statusCode,
    body: jsonDecode(await resp.readAsString()) as Map<String, dynamic>,
  );
}

/// Pairs [owner] on [h] (minting a token first) and returns the contract.
Future<Map<String, dynamic>> _pair(
  _Harness h,
  _Owner owner, {
  Map<String, dynamic>? requested,
  String? tokenOverride,
  int? timestampMs,
}) async {
  final token = tokenOverride ??
      (() {
        final e = h.server.store.addToken(ttlHours: 24, nowMs: h.nowMs);
        return e.token;
      })();
  final body = await owner.pairBody(
    h.server.keys.fingerprint,
    token,
    requested: requested,
    timestampMs: timestampMs ?? h.nowMs,
  );
  final r = await _post(h.server, RelayProtocol.pathPair, body);
  if (r.status != 200) throw StateError('pair failed: ${r.status} ${r.body}');
  return r.body;
}

Future<Map<String, dynamic>> _mailbox(
  _Harness h,
  _Owner owner,
  Map<String, dynamic> cmd,
) async {
  final r = await _post(
    h.server,
    RelayProtocol.pathMailbox,
    {'protocol': RelayProtocol.id, ...cmd},
    owner: owner,
    timestampMs: h.nowMs,
  );
  if (r.status != 200) throw StateError('mailbox failed: ${r.status} ${r.body}');
  return r.body;
}

String _deposit() => RelaySeal.randomBytes(32)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

Future<Map<String, dynamic>> _sealed(_Owner forOwner, String text) =>
    RelaySeal.seal(utf8.encode(text), forOwner.agreePublic);

void main() {
  group('manifest', () {
    test('is public and verifies against the embedded identity', () async {
      final h = await _server();
      final resp = await h.server.handler(
        Request('GET', Uri.parse('http://relay${RelayProtocol.pathManifest}')),
      );
      expect(resp.statusCode, 200);
      final manifest = RelayManifest.fromJson(
        jsonDecode(await resp.readAsString()) as Map<String, dynamic>,
      );
      expect(manifest.relayFingerprint, h.server.keys.fingerprint);
      expect(await manifest.verifySelf(), isTrue);
    });

    test('unknown path answers 404 not_found', () async {
      final h = await _server();
      final resp = await h.server.handler(
        Request('GET', Uri.parse('http://relay/nope')),
      );
      expect(resp.statusCode, 404);
      expect(jsonDecode(await resp.readAsString())['error'], 'not_found');
    });
  });

  group('pair', () {
    test('happy path: signed contract, limits clamped to the ceiling',
        () async {
      final h = await _server();
      final owner = await _Owner.create();
      final contractJson = await _pair(h, owner, requested: {
        'maxItemBytes': 1 << 30,
        'itemTtlSeconds': 1 << 30,
        'maxMailboxes': 1 << 20,
        'maxMailboxItems': 1 << 20,
        'maxTenantBytes': 1 << 40,
      });
      final contract = RelayContract.fromJson(contractJson);
      expect(contract.version, 1);
      expect(contract.ownerFingerprint, owner.fpr);
      expect(contract.relayFingerprint, h.server.keys.fingerprint);
      expect(contract.limits, h.server.config.limits);
      expect(
        await contract.verify(h.server.keys.signPublic),
        isTrue,
      );
    });

    test('re-pair with a fresh token returns version + 1', () async {
      final h = await _server();
      final owner = await _Owner.create();
      await _pair(h, owner);
      final second = await _pair(h, owner);
      expect(RelayContract.fromJson(second).version, 2);
    });

    test('reused token answers bad_token', () async {
      final h = await _server();
      final owner = await _Owner.create();
      final entry =
          h.server.store.addToken(ttlHours: 24, nowMs: h.nowMs);
      await _pair(h, owner, tokenOverride: entry.token);
      final replay = await owner.pairBody(
        h.server.keys.fingerprint,
        entry.token,
        timestampMs: h.nowMs + 1,
      );
      final r = await _post(h.server, RelayProtocol.pathPair, replay);
      expect(r.status, 403);
      expect(r.body['error'], 'bad_token');
    });

    test('tampered signature answers bad_signature', () async {
      final h = await _server();
      final owner = await _Owner.create();
      final entry =
          h.server.store.addToken(ttlHours: 24, nowMs: h.nowMs);
      final body = await owner.pairBody(
        h.server.keys.fingerprint,
        entry.token,
        timestampMs: h.nowMs,
      );
      final sig = body['sig'] as String;
      body['sig'] = '${sig.substring(0, sig.length - 1)}${sig.endsWith('A') ? 'B' : 'A'}';
      final r = await _post(h.server, RelayProtocol.pathPair, body);
      expect(r.status, 403);
      expect(r.body['error'], 'bad_signature');
    });

    test('fingerprint mismatch with ownerIdentityJson answers bad_request',
        () async {
      final h = await _server();
      final owner = await _Owner.create();
      final entry =
          h.server.store.addToken(ttlHours: 24, nowMs: h.nowMs);
      final body = await owner.pairBody(
        h.server.keys.fingerprint,
        entry.token,
        timestampMs: h.nowMs,
      );
      final idJson =
          jsonDecode(body['ownerIdentityJson'] as String) as Map<String, dynamic>;
      idJson['fingerprint'] = '0' * 64;
      body['ownerIdentityJson'] = jsonEncode(idJson);
      final r = await _post(h.server, RelayProtocol.pathPair, body);
      expect(r.status, 400);
      expect(r.body['error'], 'bad_request');
    });

    test('closed admission refuses new tenants', () async {
      final h = await _server(admission: RelayAdmission.closed);
      final owner = await _Owner.create();
      final entry =
          h.server.store.addToken(ttlHours: 24, nowMs: h.nowMs);
      final body = await owner.pairBody(
        h.server.keys.fingerprint,
        entry.token,
        timestampMs: h.nowMs,
      );
      final r = await _post(h.server, RelayProtocol.pathPair, body);
      expect(r.status, 403);
      expect(r.body['error'], 'admission_closed');
    });
    test('a token minted on disk while running is honoured', () async {
      final h = await _server();
      final owner = await _Owner.create();
      // Simulate `token new` in another process: append to tokens.json on
      // disk, leaving the server's in-memory list untouched.
      final file = File('${h.dir.path}/tokens.json');
      final raw = jsonDecode(file.readAsStringSync()) as List;
      final fresh = TokenEntry(
        token: TokenEntry.newToken(),
        createdAt: h.nowMs,
        expiresAt: h.nowMs + 3600 * 1000,
      );
      raw.add(fresh.toJson());
      file.writeAsStringSync(jsonEncode(raw));
      expect(h.server.store.findToken(fresh.token), isNull);
      final contract = await _pair(h, owner, tokenOverride: fresh.token);
      expect(RelayContract.fromJson(contract).version, 1);
    });

    test('an owner dropped from allowedOwners cannot renew', () async {
      final owner = await _Owner.create();
      final h = await _server(allowedOwners: [owner.fpr]);
      await _pair(h, owner);
      final revoked = await _restart(h, allowedOwners: ['0' * 64]);
      final token =
          revoked.server.store.addToken(ttlHours: 24, nowMs: revoked.nowMs);
      final body = await owner.pairBody(
        revoked.server.keys.fingerprint,
        token.token,
        timestampMs: revoked.nowMs,
      );
      final r = await _post(revoked.server, RelayProtocol.pathPair, body);
      expect(r.status, 403);
      expect(r.body['error'], 'admission_closed');
      // The refusal must not have spent the token either.
      expect(revoked.server.store.findToken(token.token)!.used, isFalse);
    });
  });

  group('mailbox', () {
    test('a second tenant cannot claim an address already registered',
        () async {
      final h = await _server(tenancy: RelayTenancy.public);
      final victim = await _Owner.create();
      final attacker = await _Owner.create();
      await _pair(h, victim);
      await _pair(h, attacker);
      final deposit = _deposit();
      await _mailbox(h, victim, {'op': 'put', 'deposit': deposit});

      final stolen = await _post(
        h.server,
        RelayProtocol.pathMailbox,
        {'protocol': RelayProtocol.id, 'op': 'put', 'deposit': deposit},
        owner: attacker,
        timestampMs: h.nowMs,
      );
      expect(stolen.status, 400);
      expect(stolen.body['error'], 'bad_request');
      expect(h.server.store.depositIndex[deposit], victim.fpr);

      // The channel still belongs to its owner: the deposit lands where the
      // victim picks up, not in the attacker's mailbox.
      final stored = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': await _sealed(victim, 'still mine'),
      });
      expect(stored.status, 200);
      expect(h.server.store.usageOf(victim.fpr).items, 1);
      expect(h.server.store.usageOf(attacker.fpr).items, 0);
    });
  });

  group('deposit', () {
    test('unknown address answers 404 mailbox_unknown', () async {
      final h = await _server();
      final owner = await _Owner.create();
      final r = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': _deposit(),
        'payload': await _sealed(owner, 'hello'),
      });
      expect(r.status, 404);
      expect(r.body['error'], 'mailbox_unknown');
    });

    test('disabled mailbox answers 403 mailbox_disabled; deleted is unknown',
        () async {
      final h = await _server();
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      await _mailbox(h, owner, {'op': 'disable', 'deposit': deposit});
      Future<Map<String, dynamic>> depositOnce() async {
        final r = await _post(h.server, RelayProtocol.pathDeposit, {
          'protocol': RelayProtocol.id,
          'deposit': deposit,
          'payload': await _sealed(owner, 'hello'),
        });
        return {'status': r.status, 'body': r.body};
      }

      final disabled = await depositOnce();
      expect(disabled['status'], 403);
      expect((disabled['body'] as Map)['error'], 'mailbox_disabled');
      await _mailbox(h, owner, {'op': 'delete', 'deposit': deposit});
      final deleted = await depositOnce();
      expect(deleted['status'], 404);
      expect((deleted['body'] as Map)['error'], 'mailbox_unknown');
    });

    test('payload over maxItemBytes answers 413', () async {
      final h = await _server(limits: _limits(maxItemBytes: 64));
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      final r = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': await _sealed(owner, 'x' * 200),
      });
      expect(r.status, 413);
      expect(r.body['error'], 'item_too_large');
    });

    test('past maxMailboxItems answers 507 mailbox_full', () async {
      final h = await _server(limits: _limits(maxMailboxItems: 2));
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      for (var i = 0; i < 2; i++) {
        final r = await _post(h.server, RelayProtocol.pathDeposit, {
          'protocol': RelayProtocol.id,
          'deposit': deposit,
          'payload': await _sealed(owner, 'm$i'),
        });
        expect(r.status, 200);
      }
      final full = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': await _sealed(owner, 'one-too-many'),
      });
      expect(full.status, 507);
      expect(full.body['error'], 'mailbox_full');
    });

    test('past maxTenantBytes answers 507 tenant_full', () async {
      final h = await _server(limits: _limits(maxTenantBytes: 10));
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      final r = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': await _sealed(owner, 'hello'),
      });
      expect(r.status, 507);
      expect(r.body['error'], 'tenant_full');
    });

    test('deposit rate limit answers 429', () async {
      final h = await _server(
        rate: const RelayRateConfig(
          depositPerMinute: 2,
          pickupPerMinute: 30,
          pairPerHour: 10,
        ),
      );
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      for (var i = 0; i < 2; i++) {
        final r = await _post(h.server, RelayProtocol.pathDeposit, {
          'protocol': RelayProtocol.id,
          'deposit': deposit,
          'payload': await _sealed(owner, 'm$i'),
        });
        expect(r.status, 200);
      }
      final limited = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': await _sealed(owner, 'throttled'),
      });
      expect(limited.status, 429);
      expect(limited.body['error'], 'rate_limited');
    });
  });

  group('pickup and ack', () {
    test('byte-identical payload, non-destructive pickup, ack deletes',
        () async {
      final h = await _server();
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      final sealed = await _sealed(owner, 'ping');
      final stored = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': sealed,
      });
      expect(stored.status, 200);
      final itemId = stored.body['itemId'] as String;

      Future<List<dynamic>> pickup() async {
        final r = await _post(
          h.server,
          RelayProtocol.pathPickup,
          {'protocol': RelayProtocol.id},
          owner: owner,
          timestampMs: h.nowMs,
        );
        expect(r.status, 200, reason: '${r.body}');
        h.nowMs++;
        return r.body['items'] as List<dynamic>;
      }

      final first = await pickup();
      expect(first, hasLength(1));
      expect(
        (first.single as Map)['payload'],
        equals(sealed),
      );
      final second = await pickup();
      expect(second, hasLength(1));
      expect((second.single as Map)['itemId'], itemId);

      final ack = await _post(
        h.server,
        RelayProtocol.pathAck,
        {'protocol': RelayProtocol.id, 'itemIds': [itemId]},
        owner: owner,
        timestampMs: h.nowMs,
      );
      h.nowMs++;
      expect(ack.status, 200);
      expect(ack.body, {'deleted': 1, 'unknown': 0});

      final gone = await pickup();
      expect(gone, isEmpty);

      final reack = await _post(
        h.server,
        RelayProtocol.pathAck,
        {
          'protocol': RelayProtocol.id,
          'itemIds': [itemId]
        },
        owner: owner,
        timestampMs: h.nowMs,
      );
      h.nowMs++;
      expect(reack.body, {'deleted': 0, 'unknown': 1});
    });

    test('batching: oldest first, more == true', () async {
      final h = await _server(limits: _limits(pickupBatchItems: 2));
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        final r = await _post(h.server, RelayProtocol.pathDeposit, {
          'protocol': RelayProtocol.id,
          'deposit': deposit,
          'payload': await _sealed(owner, 'm$i'),
        });
        expect(r.status, 200);
        ids.add(r.body['itemId'] as String);
        h.nowMs++;
      }
      final r = await _post(
        h.server,
        RelayProtocol.pathPickup,
        {'protocol': RelayProtocol.id},
        owner: owner,
        timestampMs: h.nowMs,
      );
      expect(r.status, 200);
      expect(r.body['more'], isTrue);
      final items = r.body['items'] as List<dynamic>;
      expect(items, hasLength(2));
      expect((items[0] as Map)['itemId'], ids[0]);
      expect((items[1] as Map)['itemId'], ids[1]);
    });
  });

  group('owner auth', () {
    test('replayed signature answers 409 replayed', () async {
      final h = await _server();
      final owner = await _Owner.create();
      await _pair(h, owner);
      final body = jsonEncode({'protocol': RelayProtocol.id});
      final headers = await owner.authHeaders(
        method: 'POST',
        path: RelayProtocol.pathPickup,
        body: body,
        relayFpr: h.server.keys.fingerprint,
        timestampMs: h.nowMs,
      );
      Future<int> send() async {
        final resp = await h.server.handler(
          Request('POST', Uri.parse('http://relay${RelayProtocol.pathPickup}'),
              body: body, headers: headers),
        );
        await resp.readAsString();
        return resp.statusCode;
      }

      expect(await send(), 200);
      expect(await send(), 409);
    });

    test('ten-minute-old timestamp answers 401 stale_request', () async {
      final h = await _server();
      final owner = await _Owner.create();
      await _pair(h, owner);
      final r = await _post(
        h.server,
        RelayProtocol.pathPickup,
        {'protocol': RelayProtocol.id},
        owner: owner,
        timestampMs: h.nowMs - 10 * 60 * 1000,
      );
      expect(r.status, 401);
      expect(r.body['error'], 'stale_request');
    });

    test('signature for another path answers 403 bad_signature', () async {
      final h = await _server();
      final owner = await _Owner.create();
      await _pair(h, owner);
      final body = jsonEncode({'protocol': RelayProtocol.id});
      final headers = await owner.authHeaders(
        method: 'POST',
        path: RelayProtocol.pathUnpair,
        body: body,
        relayFpr: h.server.keys.fingerprint,
        timestampMs: h.nowMs,
      );
      final resp = await h.server.handler(
        Request('POST', Uri.parse('http://relay${RelayProtocol.pathPickup}'),
            body: body, headers: headers),
      );
      expect(resp.statusCode, 403);
      expect(
        (jsonDecode(await resp.readAsString()) as Map)['error'],
        'bad_signature',
      );
    });

    test('unknown owner answers 403 not_paired', () async {
      final h = await _server();
      final owner = await _Owner.create();
      final body = jsonEncode({'protocol': RelayProtocol.id});
      final headers = await owner.authHeaders(
        method: 'POST',
        path: RelayProtocol.pathPickup,
        body: body,
        relayFpr: h.server.keys.fingerprint,
        timestampMs: h.nowMs,
      );
      // Never paired: same key material, unknown fingerprint.
      final unknown = Map<String, String>.of(headers);
      unknown[RelayProtocol.headerOwner] = 'd' * 64;
      final resp = await h.server.handler(
        Request('POST', Uri.parse('http://relay${RelayProtocol.pathPickup}'),
            body: body, headers: unknown),
      );
      expect(resp.statusCode, 403);
      expect(
        (jsonDecode(await resp.readAsString()) as Map)['error'],
        'not_paired',
      );
    });
  });

  group('sweeper', () {
    test('an item past its expiry disappears on sweep', () async {
      final h = await _server(limits: _limits(itemTtlSeconds: 3600));
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      final stored = await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': await _sealed(owner, 'ephemeral'),
      });
      expect(stored.status, 200);
      // Move the clock past the TTL, then sweep directly: no sleeping.
      h.nowMs += 2 * 3600 * 1000;
      final swept = await sweepStore(h.server.store, nowMs: h.nowMs);
      expect(swept.expiredItems, 1);
      final r = await _post(
        h.server,
        RelayProtocol.pathPickup,
        {'protocol': RelayProtocol.id},
        owner: owner,
        timestampMs: h.nowMs,
      );
      expect(r.status, 200);
      expect(r.body['items'], isEmpty);
    });
  });

  group('unpair', () {
    test('leaves no tenant directory behind', () async {
      final h = await _server();
      final owner = await _Owner.create();
      await _pair(h, owner);
      final deposit = _deposit();
      await _mailbox(h, owner, {'op': 'put', 'deposit': deposit});
      await _post(h.server, RelayProtocol.pathDeposit, {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': await _sealed(owner, 'last'),
      });
      final r = await _post(
        h.server,
        RelayProtocol.pathUnpair,
        {'confirm': true},
        owner: owner,
        timestampMs: h.nowMs,
      );
      h.nowMs++;
      expect(r.status, 200);
      expect(r.body, {'status': 'unpaired', 'deletedItems': 1});
      expect(
        Directory('${h.dir.path}/tenants/${owner.fpr}').existsSync(),
        isFalse,
      );
      final status = await _post(
        h.server,
        RelayProtocol.pathStatus,
        {'protocol': RelayProtocol.id},
        owner: owner,
        timestampMs: h.nowMs,
      );
      expect(status.status, 403);
      expect(status.body['error'], 'not_paired');
    });
  });
}
