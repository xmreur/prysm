import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PeerTransportMode { unknown, websocket, httpOnly }

/// Tracks which peers support WebSocket vs HTTP-only fallback.
class PeerTransportRegistry {
  PeerTransportRegistry._();

  static final PeerTransportRegistry instance = PeerTransportRegistry._();

  static const String _prefsKey = 'peer_transport_http_only';
  static const String _prefsTimestampsKey = 'peer_transport_http_only_at';

  /// After this duration, httpOnly peers are re-probed for WebSocket support.
  static const Duration httpOnlyTtl = Duration(hours: 6);

  final Map<String, PeerTransportMode> _modes = {};
  final Map<String, DateTime> _httpOnlyAt = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey);
    if (raw != null) {
      for (final peer in raw) {
        _modes[peer] = PeerTransportMode.httpOnly;
      }
    }

    final timestampsRaw = prefs.getString(_prefsTimestampsKey);
    if (timestampsRaw != null) {
      try {
        final decoded = jsonDecode(timestampsRaw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final millis = entry.value;
          if (millis is int) {
            _httpOnlyAt[entry.key] =
                DateTime.fromMillisecondsSinceEpoch(millis);
          }
        }
      } catch (_) {}
    }

    // Legacy entries without timestamps: treat as eligible for immediate re-probe.
    for (final peer in _modes.entries) {
      if (peer.value == PeerTransportMode.httpOnly &&
          !_httpOnlyAt.containsKey(peer.key)) {
        _httpOnlyAt[peer.key] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
  }

  PeerTransportMode modeFor(String peerOnion) {
    if (_modes[peerOnion] == PeerTransportMode.httpOnly && !isHttpOnly(peerOnion)) {
      return PeerTransportMode.unknown;
    }
    return _modes[peerOnion] ?? PeerTransportMode.unknown;
  }

  bool isHttpOnly(String peerOnion) {
    if (_modes[peerOnion] != PeerTransportMode.httpOnly) return false;

    final markedAt = _httpOnlyAt[peerOnion];
    if (markedAt == null) return false;

    if (DateTime.now().difference(markedAt) > httpOnlyTtl) {
      clearPeer(peerOnion);
      return false;
    }
    return true;
  }

  bool supportsWebSocket(String peerOnion) =>
      _modes[peerOnion] == PeerTransportMode.websocket;

  void markWebSocket(String peerOnion) {
    _modes[peerOnion] = PeerTransportMode.websocket;
    _httpOnlyAt.remove(peerOnion);
    if (_loaded) unawaited(_persistHttpOnlyPeers());
  }

  void markHttpOnly(String peerOnion) {
    _modes[peerOnion] = PeerTransportMode.httpOnly;
    _httpOnlyAt[peerOnion] = DateTime.now();
    if (_loaded) unawaited(_persistHttpOnlyPeers());
  }

  void clearPeer(String peerOnion) {
    _modes.remove(peerOnion);
    _httpOnlyAt.remove(peerOnion);
    if (_loaded) unawaited(_persistHttpOnlyPeers());
  }

  void clearHttpOnlyAll() {
    final httpOnlyPeers = _modes.entries
        .where((e) => e.value == PeerTransportMode.httpOnly)
        .map((e) => e.key)
        .toList();
    for (final peer in httpOnlyPeers) {
      _modes.remove(peer);
      _httpOnlyAt.remove(peer);
    }
    if (_loaded) unawaited(_persistHttpOnlyPeers());
  }

  void resetForTest() {
    _modes.clear();
    _httpOnlyAt.clear();
    _loaded = false;
  }

  /// Backdates an httpOnly mark for unit tests of [httpOnlyTtl].
  @visibleForTesting
  void setHttpOnlyAtForTest(String peerOnion, DateTime markedAt) {
    _modes[peerOnion] = PeerTransportMode.httpOnly;
    _httpOnlyAt[peerOnion] = markedAt;
  }

  Future<void> _persistHttpOnlyPeers() async {
    final prefs = await SharedPreferences.getInstance();
    final httpOnly = _modes.entries
        .where((e) => e.value == PeerTransportMode.httpOnly)
        .map((e) => e.key)
        .toList();
    await prefs.setStringList(_prefsKey, httpOnly);

    final timestamps = {
      for (final peer in httpOnly)
        peer: _httpOnlyAt[peer]?.millisecondsSinceEpoch ?? 0,
    };
    await prefs.setString(_prefsTimestampsKey, jsonEncode(timestamps));
  }

  Map<String, String> snapshotForDebug() => {
        for (final entry in _modes.entries) entry.key: entry.value.name,
      };
}
