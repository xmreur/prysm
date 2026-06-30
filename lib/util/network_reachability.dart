import 'dart:async';

import 'package:http/http.dart' as http;

/// Lightweight internet reachability probe (not just link-up).
class NetworkReachability {
  NetworkReachability._();

  static const _probeUrl = 'https://www.google.com/generate_204';

  /// Injectable probe for tests. Defaults to a short HTTP HEAD request.
  static Future<bool> Function({Duration timeout}) probe = _defaultProbe;

  static Future<bool> hasInternet({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      return await probe(timeout: timeout);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultProbe({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final response = await http
          .head(Uri.parse(_probeUrl))
          .timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 400;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
