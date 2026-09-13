import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/transport/relay_client.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/local_onion_address.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/relay_store.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

/// What happened to one picked-up item.
enum RelayItemOutcome {
  /// Handed to the inbound router and accepted: ack it.
  delivered,

  /// Unopenable or refused by the router: ack it too, or it poisons every
  /// future pickup.
  dropped,

  /// Something local failed (storage, lock): leave it on the relay and retry.
  keep,
}

/// Everything the UI needs to render the Relay section, in one value.
@immutable
class RelayState {
  final bool enabled;
  final RelayContract? contract;
  final RelayManifest? manifest;
  final RelayUsage? usage;
  final List<RelayMailboxInfo> mailboxes;
  final int? lastPickupAt;
  final int lastPickupDelivered;
  final String? lastError;

  const RelayState({
    this.enabled = false,
    this.contract,
    this.manifest,
    this.usage,
    this.mailboxes = const [],
    this.lastPickupAt,
    this.lastPickupDelivered = 0,
    this.lastError,
  });

  bool get isPaired => contract != null;

  /// Paired, switched on, and not expired: the only state in which the relay
  /// is actually used.
  bool get isActive => enabled && contract != null && !contract!.expired;

  RelayState copyWith({
    bool? enabled,
    RelayContract? contract,
    RelayManifest? manifest,
    RelayUsage? usage,
    List<RelayMailboxInfo>? mailboxes,
    int? lastPickupAt,
    int? lastPickupDelivered,
    String? lastError,
    bool clearContract = false,
    bool clearError = false,
  }) {
    return RelayState(
      enabled: enabled ?? this.enabled,
      contract: clearContract ? null : (contract ?? this.contract),
      manifest: clearContract ? null : (manifest ?? this.manifest),
      usage: clearContract ? null : (usage ?? this.usage),
      mailboxes: clearContract ? const [] : (mailboxes ?? this.mailboxes),
      lastPickupAt: lastPickupAt ?? this.lastPickupAt,
      lastPickupDelivered: lastPickupDelivered ?? this.lastPickupDelivered,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

/// A manifest the user has fetched but not yet accepted.
@immutable
class RelayPairingPreview {
  final RelayManifest manifest;
  final String relayOnion;

  /// False when the manifest's own signature does not check out against the
  /// identity it embeds. The UI must refuse to pair, not merely warn.
  final bool signatureValid;

  const RelayPairingPreview({
    required this.manifest,
    required this.relayOnion,
    required this.signatureValid,
  });
}

/// The app's side of the Relay: pairing, mailbox bookkeeping, pickup.
///
/// Deliberately the only relay-aware object the rest of the app talks to. The
/// send path asks [RelayOutboundDelivery], the profile asks
/// [buildAdvertisementFor], the sync loop asks [pickupNow]; nothing else needs
/// to know a relay exists.
class RelayService {
  RelayService._();

  static final RelayService instance = RelayService._();

  /// How long a published advertisement stays valid. Long, because a sender
  /// uses its *cached* copy exactly when the owner is unreachable, and a short
  /// window would make relays useless for anyone offline for a while.
  static const Duration advertisementTtl = Duration(days: 30);

  final ValueNotifier<RelayState> _state = ValueNotifier(const RelayState());

  KeyManager? _keyManager;
  Future<InboundHandleResult> Function(Map<String, dynamic> envelope)? _deliver;

  /// Test seam: lets a test swap the network without faking Tor.
  @visibleForTesting
  RelayClient Function(String relayOnion)? clientFactory;

  bool _pickingUp = false;

  ValueListenable<RelayState> get state => _state;

  RelayState get current => _state.value;

  /// Wires the dependencies. Called from `AppComposition` once the identity is
  /// unlocked; safe to call again after a relaunch.
  void configure({
    required KeyManager keyManager,
    Future<InboundHandleResult> Function(Map<String, dynamic> envelope)? deliver,
  }) {
    _keyManager = keyManager;
    _deliver = deliver;
  }

  /// Loads the persisted Contract and manifest. No network.
  Future<void> load() async {
    final settings = SettingsService();
    RelayContract? contract;
    RelayManifest? manifest;
    try {
      final raw = settings.relayContract;
      if (raw != null && raw.isNotEmpty) {
        contract = RelayContract.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      Logging.error('Stored relay contract unreadable: $e', 'RelayService');
    }
    try {
      final raw = settings.relayManifest;
      if (raw != null && raw.isNotEmpty) {
        manifest = RelayManifest.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      manifest = null;
    }
    _state.value = RelayState(
      enabled: settings.relayEnabled,
      contract: contract,
      manifest: manifest,
      lastPickupAt: settings.relayLastPickupAt,
    );
  }

  Future<void> setEnabled(bool value) async {
    await SettingsService().setRelayEnabled(value);
    _state.value = current.copyWith(enabled: value, clearError: true);
  }

  RelayClient _client(String relayOnion) =>
      clientFactory?.call(relayOnion) ?? RelayClient(relayOnion: relayOnion);

  /// Fetches and self-verifies a relay's manifest so the user can read the
  /// terms before agreeing to them.
  Future<RelayPairingPreview> fetchManifest(
    String relayOnion, {
    Duration timeout = RelayClient.defaultTimeout,
  }) async {
    final onion = relayOnion.trim().toLowerCase();
    if (!RelayFields.isOnion(onion)) {
      throw RelayError.badRequest('not a v3 onion address');
    }
    final manifest = await _client(onion).manifest(timeout: timeout);
    final valid = await manifest.verifySelf() && manifest.relayOnion == onion;
    return RelayPairingPreview(
      manifest: manifest,
      relayOnion: onion,
      signatureValid: valid,
    );
  }

  /// Pairs with a relay using a single-use setup token.
  Future<RelayContract> pair({
    required String relayOnion,
    required String token,
    int? maxItemBytes,
    int? itemTtlSeconds,
  }) async {
    final keyManager = _requireKeyManager();
    final preview = await fetchManifest(relayOnion);
    if (!preview.signatureValid) {
      throw const RelayError(
        RelayErrorCode.badSignature,
        'the relay manifest is not signed by the identity it claims',
      );
    }
    final ownerOnion = LocalOnionAddress.value;
    if (ownerOnion == null || ownerOnion.isEmpty) {
      throw RelayError.badRequest('the local onion address is not ready yet');
    }
    final publicIdentity = await keyManager.publicIdentity;
    final manifest = preview.manifest;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final signature = await RelaySigning.sign(
      RelaySigning.pairBytes(
        relayFingerprint: manifest.relayFingerprint,
        ownerFingerprint: publicIdentity.fingerprint,
        token: token.trim(),
        timestampMs: timestamp,
      ),
      keyManager.identity.signKeyPair,
    );
    final request = RelayPairRequest(
      token: token.trim(),
      ownerIdentityJson: keyManager.publicKeyJson,
      ownerOnion: ownerOnion,
      requested: {
        'maxItemBytes': ?maxItemBytes,
        'itemTtlSeconds': ?itemTtlSeconds,
      },
      timestamp: timestamp,
      sig: signature,
    );
    final contract = await _client(preview.relayOnion).pair(request);

    // The Contract must come from the relay we read the manifest from, and it
    // must be signed by that same identity: otherwise a relay could hand back
    // somebody else's terms.
    if (contract.relayFingerprint != manifest.relayFingerprint) {
      throw const RelayError(
        RelayErrorCode.badSignature,
        'the contract names a different relay than the manifest',
      );
    }
    if (contract.ownerFingerprint != publicIdentity.fingerprint) {
      throw const RelayError(
        RelayErrorCode.badRequest,
        'the contract was issued to a different identity',
      );
    }
    if (!await contract.verify(manifest.identity.signPublic)) {
      throw const RelayError(
        RelayErrorCode.badSignature,
        'the contract signature does not check out',
      );
    }

    // A new pairing invalidates the addresses handed out under the old one.
    final previous = current.contract;
    if (previous != null && previous.relayOnion != contract.relayOnion) {
      await RelayMailboxStore.clear();
    }

    final settings = SettingsService();
    await settings.setRelayContract(jsonEncode(contract.toJson()));
    await settings.setRelayManifest(jsonEncode(manifest.toJson()));
    await settings.setRelayEnabled(true);
    _state.value = current.copyWith(
      enabled: true,
      contract: contract,
      manifest: manifest,
      mailboxes: const [],
      usage: const RelayUsage(items: 0, bytes: 0, mailboxes: 0),
      clearError: true,
    );
    Logging.debug('Paired with a relay', 'RelayService');
    return contract;
  }

  /// Ends the Contract and deletes everything the relay holds for us.
  Future<void> unpair() async {
    final contract = current.contract;
    if (contract != null) {
      try {
        final auth = await _auth(contract);
        await _client(contract.relayOnion).authed(
          RelayProtocol.pathUnpair,
          {'protocol': RelayProtocol.id, 'confirm': true},
          auth: auth,
        );
      } catch (e) {
        // Local state is cleared regardless: a user who says "stop" must not
        // stay paired because the relay is unreachable.
        Logging.error('Unpair call failed: $e', 'RelayService');
      }
    }
    await RelayMailboxStore.clear();
    final settings = SettingsService();
    await settings.setRelayContract(null);
    await settings.setRelayManifest(null);
    await settings.setRelayEnabled(false);
    _state.value = const RelayState();
  }

  Future<RelayStatusResponse> refreshStatus() async {
    final contract = _requireContract();
    final auth = await _auth(contract);
    final json = await _client(contract.relayOnion).authed(
      RelayProtocol.pathStatus,
      {'protocol': RelayProtocol.id},
      auth: auth,
    );
    final status = RelayStatusResponse.fromJson(json);
    _state.value = current.copyWith(
      usage: status.usage,
      mailboxes: status.mailboxes,
      contract: status.contract,
      clearError: true,
    );
    return status;
  }

  /// The deposit addresses the relay holds, labelled locally with the contact
  /// they were handed to (the relay itself never learns that mapping).
  Future<Map<String, String>> mailboxLabels() =>
      RelayMailboxStore.peersByDeposit();

  Future<void> revokeMailbox(String deposit) async {
    final contract = _requireContract();
    final auth = await _auth(contract);
    await _client(contract.relayOnion).authed(
      RelayProtocol.pathMailbox,
      RelayMailboxCommand(op: RelayMailboxOp.delete, deposit: deposit).toJson(),
      auth: auth,
    );
    await RelayMailboxStore.removeByDeposit(deposit);
    _state.value = current.copyWith(
      mailboxes: current.mailboxes.where((m) => m.deposit != deposit).toList(),
      clearError: true,
    );
  }

  /// The address to publish to [peerId], creating and registering one if this
  /// contact has never been given one.
  Future<String?> ensureMailboxFor(String peerId) async {
    final state = current;
    final contract = state.contract;
    if (!state.isActive || contract == null) return null;
    try {
      final existing = await RelayMailboxStore.depositFor(
        peerId,
        contract.relayOnion,
      );
      if (existing != null) return existing;

      final mailboxCount = (await RelayMailboxStore.peersByDeposit()).length;
      if (mailboxCount >= contract.limits.maxMailboxes) {
        Logging.error(
          'Relay mailbox limit reached (${contract.limits.maxMailboxes})',
          'RelayService',
        );
        return null;
      }

      final deposit = _randomDepositAddress();
      final auth = await _auth(contract);
      await _client(contract.relayOnion).authed(
        RelayProtocol.pathMailbox,
        RelayMailboxCommand(op: RelayMailboxOp.put, deposit: deposit).toJson(),
        auth: auth,
      );
      await RelayMailboxStore.put(
        peerId: peerId,
        deposit: deposit,
        relayOnion: contract.relayOnion,
      );
      return deposit;
    } catch (e) {
      // Publishing an address the relay does not know would send the peer's
      // messages into a 404, so failure means publishing nothing this time.
      Logging.error('Could not prepare a mailbox: $e', 'RelayService');
      return null;
    }
  }

  /// The signed `relay` block to embed in the `/profile` answer for
  /// [requesterOnion]. Null when there is nothing to advertise.
  Future<Map<String, dynamic>?> buildAdvertisementFor(
    String requesterOnion,
  ) async {
    final state = current;
    final contract = state.contract;
    if (!state.isActive || contract == null) return null;
    final keyManager = _keyManager;
    if (keyManager == null || !keyManager.isUnlocked) return null;
    if (!RelayFields.isOnion(requesterOnion)) return null;
    try {
      final deposit = await ensureMailboxFor(requesterOnion);
      if (deposit == null) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      final advert = RelayAdvertisement(
        issuedAt: now,
        expiresAt: now + advertisementTtl.inMilliseconds,
        relays: [
          RelayEndpoint(
            onion: contract.relayOnion,
            deposit: deposit,
            maxItemBytes: contract.limits.maxItemBytes,
            blockSize: contract.limits.blockSize,
          ),
        ],
      );
      final fingerprint = (await keyManager.publicIdentity).fingerprint;
      final signature = await RelaySigning.sign(
        advert.signingBytes(fingerprint),
        keyManager.identity.signKeyPair,
      );
      return advert.withSignature(signature).toJson();
    } catch (e) {
      Logging.error('Could not build the advertisement: $e', 'RelayService');
      return null;
    }
  }

  /// Collects everything waiting at the relay and replays it into the normal
  /// inbound pipeline. Returns how many messages were delivered.
  ///
  /// Pickup is non-destructive on the relay side, so an item is only acked
  /// once it has been dealt with — a crash mid-pickup costs a repeat, never a
  /// message.
  Future<int> pickupNow() async {
    final state = current;
    final contract = state.contract;
    if (!state.isActive || contract == null) return 0;
    if (_pickingUp) return 0;
    _pickingUp = true;
    var delivered = 0;
    try {
      final auth = await _auth(contract);
      final client = _client(contract.relayOnion);
      // Bounded: a relay that always answers `more: true` must not spin here.
      for (var round = 0; round < 16; round++) {
        final json = await client.authed(
          RelayProtocol.pathPickup,
          const RelayPickupRequest().toJson(),
          auth: auth,
        );
        final response = RelayPickupResponse.fromJson(json);
        if (response.items.isEmpty) {
          _state.value = current.copyWith(usage: response.usage);
          break;
        }
        final acks = <String>[];
        for (final item in response.items) {
          final outcome = await _handleItem(item);
          if (outcome == RelayItemOutcome.delivered) delivered++;
          if (outcome != RelayItemOutcome.keep) acks.add(item.itemId);
        }
        if (acks.isNotEmpty) {
          await client.authed(
            RelayProtocol.pathAck,
            RelayAckRequest(acks).toJson(),
            auth: auth,
          );
        }
        _state.value = current.copyWith(usage: response.usage);
        if (!response.more) break;
        if (acks.isEmpty) {
          // Nothing could be acked, so the next round would fetch the same
          // items forever.
          break;
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await SettingsService().setRelayLastPickupAt(now);
      _state.value = current.copyWith(
        lastPickupAt: now,
        lastPickupDelivered: delivered,
        clearError: true,
      );
      if (delivered > 0) {
        Logging.debug('Relay pickup delivered $delivered', 'RelayService');
      }
      return delivered;
    } on RelayError catch (e) {
      _state.value = current.copyWith(lastError: e.code);
      Logging.error('Relay pickup failed: ${e.code}', 'RelayService');
      return delivered;
    } catch (e) {
      _state.value = current.copyWith(lastError: e.toString());
      Logging.error('Relay pickup failed: $e', 'RelayService');
      return delivered;
    } finally {
      _pickingUp = false;
    }
  }

  Future<RelayItemOutcome> _handleItem(RelayItem item) async {
    final keyManager = _keyManager;
    if (keyManager == null || !keyManager.isUnlocked) {
      // Locked app: leave it on the relay. The inbound pipeline has a
      // `pending_auth` path, but it cannot open the seal without the identity.
      return RelayItemOutcome.keep;
    }
    Map<String, dynamic> envelope;
    try {
      final plain = await RelaySeal.open(
        item.payload,
        keyManager.identity.agreeKeyPair,
      );
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map) {
        return RelayItemOutcome.dropped;
      }
      envelope = Map<String, dynamic>.from(decoded);
    } catch (e) {
      Logging.error('Unopenable relay item, dropping it: $e', 'RelayService');
      return RelayItemOutcome.dropped;
    }
    try {
      final deliver = _deliver ?? _defaultDeliver;
      final result = await deliver(envelope);
      if (result.statusCode >= 200 && result.statusCode < 300) {
        return RelayItemOutcome.delivered;
      }
      if (result.statusCode >= 500) {
        return RelayItemOutcome.keep;
      }
      // 400/403: the router refused it for good (malformed, blocked sender,
      // not addressed to us). Retrying would refuse it again.
      Logging.error(
        'Relay item refused by the inbound router (${result.statusCode})',
        'RelayService',
      );
      return RelayItemOutcome.dropped;
    } catch (e) {
      Logging.error('Failed to deliver a relay item: $e', 'RelayService');
      return RelayItemOutcome.keep;
    }
  }

  static Future<InboundHandleResult> _defaultDeliver(
    Map<String, dynamic> envelope,
  ) async {
    final router = PrysmServer.instance?.inboundRouter;
    if (router == null) {
      throw StateError('the inbound router is not available yet');
    }
    return router.handleMessage(envelope);
  }

  Future<RelayAuth> _auth(RelayContract contract) async {
    final keyManager = _requireKeyManager();
    final publicIdentity = await keyManager.publicIdentity;
    return RelayAuth(
      relayFingerprint: contract.relayFingerprint,
      ownerFingerprint: publicIdentity.fingerprint,
      signKeyPair: keyManager.identity.signKeyPair,
    );
  }

  KeyManager _requireKeyManager() {
    final keyManager = _keyManager;
    if (keyManager == null || !keyManager.isUnlocked) {
      throw RelayError.badRequest('unlock Prysm before using a relay');
    }
    return keyManager;
  }

  RelayContract _requireContract() {
    final contract = current.contract;
    if (contract == null) {
      throw const RelayError(
        RelayErrorCode.notPaired,
        'this device is not paired with a relay',
      );
    }
    return contract;
  }

  static String _randomDepositAddress() {
    final bytes = RelaySeal.randomBytes(RelayProtocol.depositAddressBytes);
    final out = StringBuffer();
    for (final byte in bytes) {
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}
