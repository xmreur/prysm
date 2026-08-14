/// Tor bridge configuration for optional obfs4 pluggable transport.
class TorBridgeConfig {
  const TorBridgeConfig({
    required this.useObfs4,
    required this.bridges,
  });

  static const TorBridgeConfig disabled = TorBridgeConfig(
    useObfs4: false,
    bridges: [],
  );

  final bool useObfs4;
  final List<String> bridges;

  bool get isActive => useObfs4 && bridges.isNotEmpty;

  Map<String, dynamic> toMethodChannelArgs() => {
    'useObfs4': useObfs4,
    'bridges': bridges,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TorBridgeConfig &&
        other.useObfs4 == useObfs4 &&
        _listEquals(other.bridges, bridges);
  }

  @override
  int get hashCode => Object.hash(useObfs4, Object.hashAll(bridges));

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
