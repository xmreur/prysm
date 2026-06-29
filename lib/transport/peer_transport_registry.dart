import 'package:shared_preferences/shared_preferences.dart';

enum PeerTransportMode { unknown, websocket }

/// Tracks peers that have successfully used WebSocket transport.
class PeerTransportRegistry {
  PeerTransportRegistry._();

  static final PeerTransportRegistry instance = PeerTransportRegistry._();

  static const String _legacyPrefsKey = 'peer_transport_http_only';
  static const String _legacyTimestampsKey = 'peer_transport_http_only_at';

  final Map<String, PeerTransportMode> _modes = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyPrefsKey);
    await prefs.remove(_legacyTimestampsKey);
  }

  PeerTransportMode modeFor(String peerOnion) =>
      _modes[peerOnion] ?? PeerTransportMode.unknown;

  /// WebSocket is always attempted; this is kept for API compatibility.
  bool isHttpOnly(String peerOnion) => false;

  bool supportsWebSocket(String peerOnion) =>
      _modes[peerOnion] == PeerTransportMode.websocket;

  void markWebSocket(String peerOnion) {
    _modes[peerOnion] = PeerTransportMode.websocket;
  }

  /// No-op — WS is always retried; HTTP is only a per-request fallback.
  void markHttpOnly(String peerOnion) {}

  void clearPeer(String peerOnion) {
    _modes.remove(peerOnion);
  }

  void clearHttpOnlyAll() {}

  void resetForTest() {
    _modes.clear();
    _loaded = false;
  }

  Map<String, String> snapshotForDebug() => {
        for (final entry in _modes.entries) entry.key: entry.value.name,
      };
}
