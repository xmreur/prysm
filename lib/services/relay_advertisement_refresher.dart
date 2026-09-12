import 'package:prysm/services/peer_identity_resolver.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/relay_store.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

/// Keeps a peer's Relay Advertisement fresh while that peer is reachable.
///
/// The advertisement is used exactly when the peer is *un*reachable, so it has
/// to be learned in advance. Contact add covers the first time; this covers
/// every later change (a peer that pairs with a relay later, rotates its
/// deposit address, or lets the advertisement expire), and it only ever runs
/// at moments the app already knows the peer is answering.
class RelayAdvertisementRefresher {
  RelayAdvertisementRefresher._();

  /// Refresh when the cached advertisement is missing, or expires within this.
  static const Duration staleWindow = Duration(days: 7);

  /// Never re-fetch the same peer more often than this, so a peer with no
  /// relay at all does not cost a profile fetch on every wake.
  static const Duration cooldown = Duration(hours: 6);

  static final Map<String, DateTime> _lastAttempt = {};

  /// Fetches [peerId]'s profile when its advertisement needs refreshing.
  /// Returns true when a fetch was actually performed.
  ///
  /// Persisting is [PeerIdentityResolver]'s job: fetching the profile is what
  /// caches the advertisement, so this only decides *whether* to fetch.
  static Future<bool> refreshIfStale(
    String peerId,
    KeyManager keyManager,
  ) async {
    if (peerId.isEmpty) return false;
    final now = DateTime.now();
    final last = _lastAttempt[peerId];
    if (last != null && now.difference(last) < cooldown) return false;
    try {
      final cached = await PeerRelayStore.load(peerId);
      if (!_needsRefresh(cached, now)) return false;
      _lastAttempt[peerId] = now;
      await PeerIdentityResolver(peerId: peerId, keyManager: keyManager)
          .fetchOverTor();
      return true;
    } catch (e) {
      Logging.error(
        'Advertisement refresh failed for ${Logging.redactOnion(peerId)}: $e',
        'RelayAdvertisement',
      );
      return false;
    }
  }

  static bool _needsRefresh(RelayAdvertisement? cached, DateTime now) {
    if (cached == null || cached.isEmpty) return true;
    final deadline = now.add(staleWindow).millisecondsSinceEpoch;
    return cached.expiresAt <= deadline;
  }

  /// Test seam: forgets the cooldown bookkeeping.
  static void resetCooldowns() => _lastAttempt.clear();
}
