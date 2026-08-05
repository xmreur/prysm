import 'dart:async';
import 'dart:typed_data';

/// Caps for inbound Tor-reachable HTTP endpoints and file-transfer frames.
///
/// Everything here is attacker-controlled from the wire: these limits exist
/// so a remote peer cannot force unbounded allocations or request rates.
class InboundLimits {
  InboundLimits._();

  /// Maximum accepted body for a monolithic `POST /message`.
  ///
  /// Derived, not arbitrary: a monolithic HTTP message may legitimately carry
  /// an attachment up to FileTransferPolicy.maxFileSizeBytes (50 MiB)
  /// base64-encoded into the JSON envelope. Base64 expands by 4/3, so the
  /// ciphertext alone is 50 MiB * 4/3 ≈ 66.7 MiB of base64 text, and the JSON
  /// envelope, wrapped key and crypto framing add a little more. 96 MiB is
  /// that bound with slack.
  static const int maxMessageBodyBytes = 96 * 1024 * 1024;

  /// Maximum accepted body for `POST /sync-hint`, which carries a handful of
  /// short fields.
  static const int maxControlBodyBytes = 64 * 1024;

  /// Fixed-window rate-limiting defaults for [InboundRateLimiter].
  static const Duration rateWindow = Duration(seconds: 10);
  static const int maxRequestsPerSenderPerWindow = 30;
  static const int maxRequestsPerWindow = 200;

  /// Maximum concurrent inbound file transfers accepted before new begin
  /// frames are rejected.
  static const int maxConcurrentInboundTransfers = 8;

  /// Reads [body] into memory while enforcing [maxBytes] during streaming.
  ///
  /// The cap is checked as each chunk arrives, before it is accumulated, so a
  /// hostile peer streaming an unbounded body cannot force an unbounded
  /// allocation: as soon as the running total exceeds [maxBytes] the source
  /// stream is abandoned (its subscription cancelled) and
  /// [PayloadTooLargeException] is thrown. Reading the whole stream and only
  /// then comparing lengths would defeat the fix — the allocation would
  /// already have happened.
  static Future<List<int>> readCapped(
    Stream<List<int>> body,
    int maxBytes,
  ) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in body) {
      total += chunk.length;
      if (total > maxBytes) {
        throw PayloadTooLargeException(maxBytes);
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

/// Thrown when an inbound HTTP request body exceeds its configured cap.
///
/// Distinct from [FormatException]: callers map this to HTTP 413 while
/// [FormatException] means "malformed request" (400).
class PayloadTooLargeException implements Exception {
  PayloadTooLargeException(this.maxBytes);

  /// The cap that was exceeded, in bytes.
  final int maxBytes;

  @override
  String toString() => 'PayloadTooLargeException: body exceeds $maxBytes bytes';
}
