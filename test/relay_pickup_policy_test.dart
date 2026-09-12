import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/relay_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/relay_client.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the relay pickup does with an item it has just handed over is the one
/// piece of relay logic that can lose a message: acking an item the app could
/// not deal with deletes it from the relay forever, and *not* acking an item
/// the router will always refuse wedges every future pickup behind it.
///
/// Live testing proved the happy path (a message delivered to a peer that was
/// powered off). These tests pin the three outcomes of
/// `RelayItemOutcome`: delivered -> ack, dropped -> ack, keep -> never ack.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const relayFingerprint =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const relayOnion =
      'abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion';
  const ownerOnion =
      'bcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwxy.onion';
  const deposit =
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

  late IdentityKeyPair owner;
  late KeyManager keys;
  late _FakeRelay relay;

  /// Seals an envelope the way a sender does: to [agreePublic], verbatim.
  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> envelope,
    List<int> agreePublic,
  ) => RelaySeal.seal(utf8.encode(jsonEncode(envelope)), agreePublic);

  Map<String, dynamic> envelopeFor(String id) => {
    'id': id,
    'senderId': 'sender.onion',
    'receiverId': ownerOnion,
    'message': 'ciphertext',
    'type': 'text',
    'timestamp': 1700000000000,
  };

  RelayItem item(String id, Map<String, dynamic> payload) => RelayItem(
    itemId: id,
    deposit: deposit,
    storedAt: 1700000000000,
    expiresAt: 1900000000000,
    size: 1072,
    payload: payload,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService().init();
    // The relay signs every owner-authenticated request with the identity
    // fingerprint read back from the key store.
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();

    owner = await IdentityKeyPair.generate();
    await CryptoKeyStore.write(
      CryptoKeyStore.publicIdentityKey,
      jsonEncode(await owner.toPublicJson()),
    );
    keys = KeyManager.fromIdentity(owner);
    relay = _FakeRelay();

    final publicKeys = await keys.publicIdentity;
    final contract = RelayContract(
      version: 1,
      relayFingerprint: relayFingerprint,
      relayOnion: relayOnion,
      ownerFingerprint: publicKeys.fingerprint,
      ownerOnion: ownerOnion,
      tenancy: RelayTenancy.private,
      limits: const RelayLimits(
        maxItemBytes: 2 * 1024 * 1024,
        maxMailboxItems: 256,
        maxTenantBytes: 64 * 1024 * 1024,
        itemTtlSeconds: 20 * 86400,
        maxMailboxes: 512,
      ),
      issuedAt: 1700000000000,
    );
    await SettingsService().setRelayContract(jsonEncode(contract.toJson()));
    await SettingsService().setRelayEnabled(true);

    RelayService.instance.clientFactory = (_) => relay;
    await RelayService.instance.load();
  });

  tearDown(() {
    RelayService.instance.clientFactory = null;
    RelayService.instance.configure(keyManager: KeyManager());
  });

  test('an accepted item is acked and counted as delivered', () async {
    relay.items = [item('i-ok', await seal(envelopeFor('m1'), await _agree(owner)))];
    RelayService.instance.configure(
      keyManager: keys,
      deliver: (envelope) async {
        relay.delivered.add(envelope);
        return InboundHandleResult.ok({'status': 'ok'});
      },
    );

    expect(await RelayService.instance.pickupNow(), 1);
    expect(relay.acked, ['i-ok']);
    // The envelope must arrive at the router byte-identical: a re-wrapped
    // envelope would fail `_validateAddressedToLocal` with a 403.
    expect(relay.delivered.single, envelopeFor('m1'));
    expect(RelayService.instance.current.lastPickupDelivered, 1);
  });

  test('a server-side failure keeps the item on the relay', () async {
    relay.items = [item('i-5xx', await seal(envelopeFor('m2'), await _agree(owner)))];
    RelayService.instance.configure(
      keyManager: keys,
      deliver: (_) async => InboundHandleResult.internalError(),
    );

    expect(await RelayService.instance.pickupNow(), 0);
    expect(relay.acked, isEmpty);
  });

  test('a thrown delivery keeps the item on the relay', () async {
    relay.items = [item('i-throw', await seal(envelopeFor('m3'), await _agree(owner)))];
    RelayService.instance.configure(
      keyManager: keys,
      deliver: (_) async => throw StateError('storage is locked'),
    );

    expect(await RelayService.instance.pickupNow(), 0);
    expect(relay.acked, isEmpty);
  });

  test('an item the router refuses for good is acked, not delivered', () async {
    relay.items = [item('i-400', await seal(envelopeFor('m4'), await _agree(owner)))];
    RelayService.instance.configure(
      keyManager: keys,
      deliver: (_) async => InboundHandleResult.badRequest('malformed'),
    );

    expect(await RelayService.instance.pickupNow(), 0);
    expect(relay.acked, ['i-400']);
  });

  test('an item sealed to another identity is acked without delivery', () async {
    final stranger = await IdentityKeyPair.generate();
    relay.items = [
      item('i-poison', await seal(envelopeFor('m5'), await _agree(stranger))),
    ];
    var deliveries = 0;
    RelayService.instance.configure(
      keyManager: keys,
      deliver: (_) async {
        deliveries++;
        return InboundHandleResult.ok({'status': 'ok'});
      },
    );

    expect(await RelayService.instance.pickupNow(), 0);
    expect(relay.acked, ['i-poison']);
    expect(deliveries, 0);
  });

  test('a batch acks only what it dealt with', () async {
    relay.items = [
      item('i-a', await seal(envelopeFor('ma'), await _agree(owner))),
      item('i-b', await seal(envelopeFor('mb'), await _agree(owner))),
      item('i-c', await seal(envelopeFor('mc'), await _agree(owner))),
    ];
    RelayService.instance.configure(
      keyManager: keys,
      deliver: (envelope) async => envelope['id'] == 'mb'
          ? InboundHandleResult.internalError()
          : InboundHandleResult.ok({'status': 'ok'}),
    );

    expect(await RelayService.instance.pickupNow(), 2);
    expect(relay.acked, ['i-a', 'i-c']);
  });

  test('more:true with nothing ackable stops instead of looping', () async {
    relay.items = [item('i-keep', await seal(envelopeFor('m6'), await _agree(owner)))];
    relay.more = true;
    RelayService.instance.configure(
      keyManager: keys,
      deliver: (_) async => InboundHandleResult.internalError(),
    );

    expect(await RelayService.instance.pickupNow(), 0);
    expect(relay.acked, isEmpty);
    expect(relay.pickups, 1);
  });

  test('a locked app picks up nothing and acks nothing', () async {
    relay.items = [item('i-locked', await seal(envelopeFor('m7'), await _agree(owner)))];
    RelayService.instance.configure(keyManager: KeyManager());

    expect(await RelayService.instance.pickupNow(), 0);
    expect(relay.pickups, 0);
    expect(relay.acked, isEmpty);
  });

  test('pickup is skipped while the relay is switched off', () async {
    relay.items = [item('i-off', await seal(envelopeFor('m8'), await _agree(owner)))];
    RelayService.instance.configure(keyManager: keys);
    await RelayService.instance.setEnabled(false);

    expect(await RelayService.instance.pickupNow(), 0);
    expect(relay.pickups, 0);
  });
}

Future<List<int>> _agree(IdentityKeyPair identity) async =>
    (await identity.agreePublicKey).bytes;

/// A relay that answers on the wire shape only: the test swaps the network,
/// not the protocol.
class _FakeRelay extends RelayClient {
  _FakeRelay() : super(relayOnion: 'fake.onion', socksPort: 9050);

  List<RelayItem> items = [];
  bool more = false;
  int pickups = 0;
  final List<String> acked = [];
  final List<Map<String, dynamic>> delivered = [];

  @override
  Future<Map<String, dynamic>> authed(
    String path,
    Map<String, dynamic> body, {
    required RelayAuth auth,
    Duration timeout = RelayClient.defaultTimeout,
    int maxAttempts = 2,
  }) async {
    if (path == RelayProtocol.pathPickup) {
      pickups++;
      final response = RelayPickupResponse(
        items: items,
        more: more,
        usage: RelayUsage(items: items.length, bytes: 1072, mailboxes: 1),
      );
      return response.toJson();
    }
    if (path == RelayProtocol.pathAck) {
      final ids = RelayAckRequest.fromJson(body).itemIds;
      acked.addAll(ids);
      items = items.where((i) => !ids.contains(i.itemId)).toList();
      return RelayAckResponse(deleted: ids.length, unknown: 0).toJson();
    }
    throw StateError('unexpected path $path');
  }
}
