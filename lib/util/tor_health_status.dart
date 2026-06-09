class TorHealthStatus {
  final bool ok;
  final String? reason;

  const TorHealthStatus({required this.ok, this.reason});

  static const TorHealthStatus healthy = TorHealthStatus(ok: true);
}

/// Parses Tor GETINFO status/bootstrap-phase response lines.
int? parseBootstrapProgress(Iterable<String> lines) {
  final line = lines.firstWhere(
    (l) => l.contains('status/bootstrap-phase='),
    orElse: () => '',
  );
  final match = RegExp(r'PROGRESS=(\d+)').firstMatch(line);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Returns false when network-liveness reports netdown.
bool isNetworkLive(Iterable<String> lines) {
  final line = lines.firstWhere(
    (l) => l.contains('network-liveness='),
    orElse: () => '',
  );
  if (line.isEmpty) return true;
  return !line.contains('netdown');
}
