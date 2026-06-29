import 'dart:convert';

/// QR payload: onion address + identity fingerprint for contact trust.
class QrPayload {
  const QrPayload({
    required this.onion,
    required this.fingerprint,
  });

  final String onion;
  final String fingerprint;

  static const String prefix = 'prysm:v2:';

  String encode() => '$prefix$onion:$fingerprint';

  static QrPayload? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith(prefix)) {
      final body = trimmed.substring(prefix.length);
      final colon = body.lastIndexOf(':');
      if (colon <= 0) return null;
      return QrPayload(
        onion: body.substring(0, colon),
        fingerprint: body.substring(colon + 1),
      );
    }
    if (trimmed.startsWith('{')) {
      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;
        final onion = json['onion'] as String?;
        final fingerprint = json['fingerprint'] as String?;
        if (onion == null || fingerprint == null) return null;
        return QrPayload(onion: onion, fingerprint: fingerprint);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
