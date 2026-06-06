/// In-memory TTL for peer profile fetches (reduces Tor /profile spam).
class PeerProfileCache {
  PeerProfileCache._();
  static final PeerProfileCache instance = PeerProfileCache._();

  static const Duration ttl = Duration(minutes: 5);

  final Map<String, DateTime> _fetchedAt = {};

  bool shouldFetch(String peerId) {
    final at = _fetchedAt[peerId];
    if (at == null) return true;
    return DateTime.now().difference(at) > ttl;
  }

  void markFetched(String peerId) {
    _fetchedAt[peerId] = DateTime.now();
  }

  void invalidate(String peerId) {
    _fetchedAt.remove(peerId);
  }
}
