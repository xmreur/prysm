/// The shelf pipeline + hand-rolled router (no `shelf_router`) for the eight
/// endpoints of spec §3, with a body-size cap and a single error funnel that
/// turns [RelayError] into `{error, message}` with [RelayErrorCode.httpStatus].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'auth.dart';
import 'config.dart';
import 'identity.dart';
import 'log.dart';
import 'rate_limiter.dart';
import 'store.dart';
import 'sweeper.dart';

const String relaySoftware = 'prysm-relay/1.0.0';

class RelayServer {
  RelayServer({
    required this.config,
    required this.keys,
    required this.store,
    required this.log,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    depositLimiter = RelayRateLimiter(
      window: const Duration(minutes: 1),
      maxPerKey: config.rate.depositPerMinute,
      now: _clock,
    );
    pickupLimiter = RelayRateLimiter(
      window: const Duration(minutes: 1),
      maxPerKey: config.rate.pickupPerMinute,
      now: _clock,
    );
    pairLimiter = RelayRateLimiter(
      window: const Duration(hours: 1),
      maxPerKey: config.rate.pairPerHour,
      now: _clock,
    );
  }

  final RelayConfig config;
  final RelayKeyPair keys;
  final RelayStore store;
  final RelayLog log;
  final DateTime Function() _clock;

  late final RelayRateLimiter depositLimiter;
  late final RelayRateLimiter pickupLimiter;
  late final RelayRateLimiter pairLimiter;
  final RelayAuthCache replays = RelayAuthCache();
  final Uuid _uuid = const Uuid();
  Timer? _sweepTimer;

  int get maxBodyBytes => config.limits.maxItemBytes + 4096;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  Handler get handler => _route;

  void startSweeper() {
    _sweepTimer ??= Timer.periodic(const Duration(seconds: 60), (_) async {
      final swept = await sweep();
      if (swept.expiredItems > 0 || swept.droppedTokens > 0) {
        log.event(
          'sweep: expiredItems=${swept.expiredItems} '
          'droppedTokens=${swept.droppedTokens}',
        );
      }
    });
  }

  void stopSweeper() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  Future<SweepResult> sweep() => sweepStore(store, nowMs: _nowMs, log: log);

  // -- routing ---------------------------------------------------------------

  Future<Response> _route(Request request) async {
    try {
      final path = request.requestedUri.path;
      if (request.method == 'GET' && path == RelayProtocol.pathManifest) {
        return await _handleManifest();
      }
      if (request.method == 'POST' && path == RelayProtocol.pathPair) {
        return await _handlePair(await _readBody(request));
      }
      if (request.method == 'POST' && path == RelayProtocol.pathMailbox) {
        final body = await _readBody(request);
        return await _handleMailbox(request, body);
      }
      if (request.method == 'POST' && path == RelayProtocol.pathDeposit) {
        return await _handleDeposit(await _readBody(request));
      }
      if (request.method == 'POST' && path == RelayProtocol.pathPickup) {
        final body = await _readBody(request);
        return await _handlePickup(request, body);
      }
      if (request.method == 'POST' && path == RelayProtocol.pathAck) {
        final body = await _readBody(request);
        return await _handleAck(request, body);
      }
      if (request.method == 'POST' && path == RelayProtocol.pathStatus) {
        final body = await _readBody(request);
        return await _handleStatus(request, body);
      }
      if (request.method == 'POST' && path == RelayProtocol.pathUnpair) {
        final body = await _readBody(request);
        return await _handleUnpair(request, body);
      }
      return _err(
        const RelayError(RelayErrorCode.notFound, 'unknown path'),
      );
    } on RelayError catch (e) {
      return _err(e);
    } on FormatException catch (e) {
      return _err(RelayError.badRequest('malformed json: ${e.message}'));
    } catch (_) {
      return _err(
        const RelayError(RelayErrorCode.internal, 'internal error'),
      );
    }
  }

  Future<List<int>> _readBody(Request request) async {
    final out = <int>[];
    await for (final chunk in request.read()) {
      out.addAll(chunk);
      if (out.length > maxBodyBytes) {
        throw const RelayError(
          RelayErrorCode.itemTooLarge,
          'body exceeds the relay item ceiling',
        );
      }
    }
    return out;
  }

  Map<String, dynamic> _parseMap(List<int> body) {
    if (body.isEmpty) throw RelayError.badRequest('empty body');
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) throw RelayError.badRequest('body must be an object');
    return Map<String, dynamic>.from(decoded);
  }

  Future<String> _auth(Request request, List<int> body) =>
      authenticateOwner(
        request: request,
        bodyBytes: body,
        relayFingerprint: keys.fingerprint,
        lookupSignKey: (owner) => store.tenants[owner]?.ownerSignPublic,
        replays: replays,
        now: _clock(),
      );

  Response _json(int status, Map<String, dynamic> body) => Response(
        status,
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      );

  Response _err(RelayError e) => _json(e.httpStatus, e.toJson());

  // -- 3.1 manifest (public) ---------------------------------------------------

  Future<Response> _handleManifest() async {
    final manifest = RelayManifest(
      relayFingerprint: keys.fingerprint,
      relayIdentityJson: keys.toIdentityJsonString(),
      relayOnion: config.onion,
      tenancy: config.tenancy,
      admission: config.admission,
      limits: config.limits,
      terms: config.terms,
      software: relaySoftware,
      issuedAt: _nowMs,
    );
    final sig = await keys.sign(manifest.signingBytes());
    return _json(200, manifest.withSignature(sig).toJson());
  }

  // -- 3.2 pair ------------------------------------------------------------------

  Future<Response> _handlePair(List<int> body) async {
    final req = RelayPairRequest.fromJson(_parseMap(body));
    final now = _clock();
    if (!RelaySigning.freshTimestamp(req.timestamp, now: now)) {
      throw const RelayError(
        RelayErrorCode.staleRequest,
        'timestamp outside the accepted clock skew',
      );
    }
    // Recompute the owner fingerprint from the identity JSON and reject a
    // mismatch — the same rule as `IdentityKeyPair.parsePeerIdentity`.
    // `RelayIdentity.parse` also enforces the crypto version and key sizes.
    final ownerIdentity = RelayIdentity.parse(req.ownerIdentityJson);
    final ownerFpr = ownerIdentity.fingerprint;
    final pairOk = await RelaySigning.verify(
      message: RelaySigning.pairBytes(
        relayFingerprint: keys.fingerprint,
        ownerFingerprint: ownerFpr,
        token: req.token,
        timestampMs: req.timestamp,
      ),
      signatureB64: req.sig,
      ed25519PublicKey: ownerIdentity.signPublic,
    );
    if (!pairOk) {
      throw const RelayError(
        RelayErrorCode.badSignature,
        'bad pair signature',
      );
    }

    // `allowedOwners` is a whitelist *and* a revocation list: an operator who
    // takes a fingerprint out of it means "not this owner any more", so it
    // gates renewals too, not only first contracts.
    if (config.allowedOwners.isNotEmpty &&
        !config.allowedOwners.contains(ownerFpr)) {
      throw const RelayError(
        RelayErrorCode.admissionClosed,
        'this relay is not accepting this owner',
      );
    }

    // The token read-modify-write is held under the store's cross-process
    // lock: `token new` in another process must not overwrite the
    // consumption this pairing records, nor lose its own token to it.
    final signed = await store.withTokenLock(() async {
      // Tokens minted by `token new` while the relay runs land on disk first;
      // pick them up here so the operator never restarts for a token.
      await store.reloadTokens();
      final existing = store.tenants[ownerFpr];
      if (existing == null) {
        if (config.admission == RelayAdmission.closed) {
          throw const RelayError(
            RelayErrorCode.admissionClosed,
            'this relay is not accepting new contracts',
          );
        }
        if (config.tenancy == RelayTenancy.private &&
            store.tenants.isNotEmpty) {
          throw const RelayError(
            RelayErrorCode.admissionClosed,
            'this private relay already serves an owner',
          );
        }
      }
      if (!pairLimiter.allow('pair:$ownerFpr')) {
        throw const RelayError(
          RelayErrorCode.rateLimited,
          'too many pair attempts; try again later',
        );
      }
      // Invite relays require a fresh token for a renewal too; closed relays
      // let an existing owner renew on signature alone.
      if (config.admission == RelayAdmission.invite) {
        _consumeToken(req.token, ownerFpr);
      }

      // Re-pairing the same identity is idempotent: same tenant, version + 1.
      final version = existing == null
          ? 1
          : RelayContract.fromJson(
                Map<String, dynamic>.from(existing.contractJson),
              ).version +
              1;
      // Signed *before* it is stored: a crash between two writes used to
      // leave `contract.json` without its signature, and a tenant reloaded
      // from that file hands the owner a contract that can never verify.
      final contract = _contractFor(
        version: version,
        ownerFingerprint: ownerFpr,
        ownerOnion: req.ownerOnion,
        requested: req.requested,
      );
      final issued =
          contract.withSignature(await keys.sign(contract.signingBytes()));
      await store.putTenant(
        ownerFpr,
        issued.toJson(),
        ownerIdentity.signPublic,
        ownerIdentity.agreePublic,
      );
      await store.saveTokens();
      log.event(
        existing == null
            ? 'pair: new tenant ${RelayLog.shortId(ownerFpr, 8)}'
            : 'pair: renewed tenant ${RelayLog.shortId(ownerFpr, 8)} '
                'version=$version',
      );
      return issued;
    });
    return _json(200, signed.toJson());
  }

  RelayContract _contractFor({
    required int version,
    required String ownerFingerprint,
    required String ownerOnion,
    required Map<String, dynamic> requested,
  }) =>
      RelayContract(
        version: version,
        relayFingerprint: keys.fingerprint,
        relayOnion: config.onion,
        ownerFingerprint: ownerFingerprint,
        ownerOnion: ownerOnion,
        tenancy: config.tenancy,
        limits: config.limits.clamp(requested),
        issuedAt: _nowMs,
      );

  void _consumeToken(String token, String ownerFpr) {
    final entry = store.findToken(token);
    if (entry == null || entry.used || entry.expiredAt(_nowMs)) {
      throw const RelayError(RelayErrorCode.badToken, 'unknown or used token');
    }
    entry.usedBy = ownerFpr;
  }

  // -- 3.3 mailbox (owner-authenticated) -------------------------------------------

  Future<Response> _handleMailbox(Request request, List<int> body) async {
    final owner = await _auth(request, body);
    final tenant = store.tenants[owner]!;
    final cmd = RelayMailboxCommand.fromJson(_parseMap(body));
    switch (cmd.op) {
      case RelayMailboxOp.put:
        final deposit = cmd.deposit!;
        final limits = tenant.limits();
        if (!tenant.mailboxes.containsKey(deposit) &&
            tenant.mailboxes.length >= limits.maxMailboxes) {
          throw RelayError.badRequest('mailbox limit reached');
        }
        // A per-mailbox quota may only tighten what the relay signed: the
        // deposit path reads `policy.maxItems ?? limits.maxMailboxItems`, so
        // accepting a larger value would let the owner raise its own ceiling.
        if ((cmd.maxItems ?? 0) > limits.maxMailboxItems ||
            (cmd.maxBytes ?? 0) > limits.maxTenantBytes) {
          throw RelayError.badRequest(
            'maxItems/maxBytes must not exceed the contract limits',
          );
        }
        final prev = tenant.mailboxes[deposit];
        await store.putMailbox(
          owner,
          deposit,
          MailboxPolicy(
            label: cmd.label ?? prev?.label,
            // `put` registers or updates an address; it preserves the enabled
            // flag of an existing mailbox and enables a new one.
            enabled: prev?.enabled ?? true,
            maxItems: cmd.maxItems ?? prev?.maxItems,
            maxBytes: cmd.maxBytes ?? prev?.maxBytes,
          ),
        );
        log.event('mailbox put ${RelayLog.shortId(deposit)}');
        return _json(200, {'status': 'ok', 'deposit': deposit});
      case RelayMailboxOp.disable:
        final policy = tenant.mailboxes[cmd.deposit];
        if (policy == null) {
          throw const RelayError(
            RelayErrorCode.mailboxUnknown,
            'unknown deposit address',
          );
        }
        policy.enabled = false;
        await store.putMailbox(owner, cmd.deposit!, policy);
        log.event('mailbox disable ${RelayLog.shortId(cmd.deposit!)}');
        return _json(200, {'status': 'ok', 'deposit': cmd.deposit});
      case RelayMailboxOp.delete:
        if (!tenant.mailboxes.containsKey(cmd.deposit)) {
          throw const RelayError(
            RelayErrorCode.mailboxUnknown,
            'unknown deposit address',
          );
        }
        final died = await store.removeMailbox(owner, cmd.deposit!);
        log.event(
          'mailbox delete ${RelayLog.shortId(cmd.deposit!)} died=$died',
        );
        return _json(
          200,
          {'status': 'ok', 'deposit': cmd.deposit, 'deletedItems': died},
        );
      case RelayMailboxOp.list:
        return _json(200, {
          'mailboxes': [
            for (final info in store.mailboxInfos(owner)) info.toJson(),
          ],
        });
    }
  }

  // -- 3.4 deposit (capability-authenticated) ---------------------------------------

  Future<Response> _handleDeposit(List<int> body) async {
    // `RelayDepositRequest.fromJson` also enforces the sealed-payload shape:
    // the relay stays content-blind but refuses obvious garbage early.
    final req = RelayDepositRequest.fromJson(_parseMap(body));
    final ownerFpr = store.depositIndex[req.deposit];
    final tenant = ownerFpr == null ? null : store.tenants[ownerFpr];
    final policy = tenant?.mailboxes[req.deposit];
    if (tenant == null || policy == null) {
      // Deliberately the same answer for "never existed" and "revoked", so
      // probing learns nothing.
      throw const RelayError(
        RelayErrorCode.mailboxUnknown,
        'unknown deposit address',
      );
    }
    if (!policy.enabled) {
      throw const RelayError(
        RelayErrorCode.mailboxDisabled,
        'this mailbox is not accepting deposits',
      );
    }
    if (!depositLimiter.allow('deposit:${req.deposit}')) {
      throw const RelayError(
        RelayErrorCode.rateLimited,
        'too many deposits for this address; try again later',
      );
    }
    final limits = tenant.limits();
    final size = utf8.encode(canonicalJson(req.payload)).length;
    if (size > limits.maxItemBytes) {
      throw const RelayError(
        RelayErrorCode.itemTooLarge,
        'payload exceeds maxItemBytes',
      );
    }
    var boxItems = 0;
    var boxBytes = 0;
    for (final item in tenant.items.values) {
      if (item.deposit != req.deposit) continue;
      boxItems++;
      boxBytes += item.size;
    }
    // A stored per-mailbox cap can predate a narrower Contract: a renewal
    // keeps the mailbox policies (`putTenant`) and `mailbox put` carries the
    // old value forward, so the signed limit wins here even though `put`
    // already refuses a cap above the one in force.
    final policyMaxItems = policy.maxItems;
    final effectiveMaxItems = policyMaxItems == null
        ? limits.maxMailboxItems
        : min(policyMaxItems, limits.maxMailboxItems);
    if (boxItems >= effectiveMaxItems) {
      throw const RelayError(
        RelayErrorCode.mailboxFull,
        'mailbox is full; try again later',
      );
    }
    if (policy.maxBytes != null && boxBytes + size > policy.maxBytes!) {
      throw const RelayError(
        RelayErrorCode.mailboxFull,
        'mailbox byte quota exceeded; try again later',
      );
    }
    if (store.usageOf(ownerFpr!).bytes + size > limits.maxTenantBytes) {
      throw const RelayError(
        RelayErrorCode.tenantFull,
        'tenant byte quota exceeded; try again later',
      );
    }
    final nowMs = _nowMs;
    final item = StoredItem(
      itemId: _uuid.v4(),
      deposit: req.deposit,
      storedAt: nowMs,
      expiresAt: nowMs + limits.itemTtlSeconds * 1000,
      size: size,
      payload: req.payload,
    );
    await store.putItem(ownerFpr, item);
    log.event(
      'deposit ${RelayLog.shortId(req.deposit)} size=$size box=${boxItems + 1}',
    );
    return _json(
      200,
      RelayDepositResponse(itemId: item.itemId, expiresAt: item.expiresAt)
          .toJson(),
    );
  }

  // -- 3.5 pickup (owner-authenticated, non-destructive) -----------------------------

  Future<Response> _handlePickup(Request request, List<int> body) async {
    final owner = await _auth(request, body);
    if (!pickupLimiter.allow('owner:$owner')) {
      throw const RelayError(
        RelayErrorCode.rateLimited,
        'too many pickups; try again later',
      );
    }
    final tenant = store.tenants[owner]!;
    final req = RelayPickupRequest.fromJson(_parseMap(body));
    final limits = tenant.limits();
    final all = tenant.items.values.toList()
      ..sort((a, b) {
        final c = a.storedAt.compareTo(b.storedAt);
        return c != 0 ? c : a.itemId.compareTo(b.itemId);
      });
    var cap = limits.pickupBatchItems;
    if (req.max != null && req.max! < cap) cap = req.max!;
    final taken = <StoredItem>[];
    var takenBytes = 0;
    for (final item in all) {
      if (taken.length >= cap) break;
      if (taken.isNotEmpty &&
          takenBytes + item.size > limits.pickupBatchBytes) {
        break;
      }
      // Always return at least one item when any exist: a single item larger
      // than the byte cap must still be retrievable, or the client would spin
      // on `more: true` forever.
      taken.add(item);
      takenBytes += item.size;
    }
    final more = taken.length < all.length;
    log.event('pickup items=${taken.length} more=$more');
    return _json(
      200,
      RelayPickupResponse(
        items: [for (final i in taken) i.toRelayItem()],
        more: more,
        usage: store.usageOf(owner),
      ).toJson(),
    );
  }

  // -- 3.6 ack -----------------------------------------------------------------------

  Future<Response> _handleAck(Request request, List<int> body) async {
    final owner = await _auth(request, body);
    final tenant = store.tenants[owner]!;
    final req = RelayAckRequest.fromJson(_parseMap(body));
    var deleted = 0;
    var unknown = 0;
    for (final id in req.itemIds) {
      final item = tenant.items[id];
      if (item == null) {
        // Acking an already-deleted id is not an error.
        unknown++;
      } else {
        await store.removeItem(owner, item);
        deleted++;
      }
    }
    if (deleted > 0) log.event('ack deleted=$deleted unknown=$unknown');
    return _json(
      200,
      RelayAckResponse(deleted: deleted, unknown: unknown).toJson(),
    );
  }

  // -- 3.7 status ----------------------------------------------------------------------

  Future<Response> _handleStatus(Request request, List<int> body) async {
    final owner = await _auth(request, body);
    final tenant = store.tenants[owner]!;
    // The stored contract is returned verbatim (not re-parsed): it is already
    // signed, and re-parsing would only add failure modes.
    return _json(200, {
      'contract': tenant.contractJson,
      'usage': store.usageOf(owner).toJson(),
      'limits': tenant.limits().toJson(),
      'serverTime': _nowMs,
      'mailboxes': [
        for (final info in store.mailboxInfos(owner)) info.toJson(),
      ],
    });
  }

  // -- 3.8 unpair ------------------------------------------------------------------------

  Future<Response> _handleUnpair(Request request, List<int> body) async {
    final owner = await _auth(request, body);
    final map = _parseMap(body);
    if (map['confirm'] != true) {
      throw RelayError.badRequest('unpair requires {"confirm": true}');
    }
    final died = await store.removeTenant(owner);
    log.event('unpair died=$died');
    return _json(200, {'status': 'unpaired', 'deletedItems': died});
  }
}
