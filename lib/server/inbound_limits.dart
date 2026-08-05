import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

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

  /// Shared cap on the total bytes held in memory by all in-flight request
  /// bodies at once.
  ///
  /// Derived: one full-size monolithic 96 MiB message
  /// ([maxMessageBodyBytes]) plus 32 MiB of slack for concurrent smaller
  /// bodies, so a single legitimate maximum-size attachment always fits while
  /// concurrent slow-drip connections cannot accumulate unbounded memory
  /// across rate-limit windows.
  static const int maxInFlightBodyBytes = 128 * 1024 * 1024;

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
    int maxBytes, {
    InboundBodyBudget? budget,
  }) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    try {
      await for (final chunk in body) {
        // Charge the shared in-flight budget as bytes arrive, before they
        // are accumulated, so concurrent slow-drip bodies cannot hold more
        // than [InboundBodyBudget] across connections. Refusal aborts the
        // read immediately: the subscription is cancelled by the throw and
        // nothing further is drained from the source.
        if (budget != null && !budget.tryReserve(chunk.length)) {
          throw ServerBusyException();
        }
        total += chunk.length;
        if (total > maxBytes) {
          throw PayloadTooLargeException(maxBytes);
        }
        builder.add(chunk);
      }
    } finally {
      // Release everything reserved for this body — on success, on
      // [PayloadTooLargeException], on [ServerBusyException] refusal, on an
      // abort or on a client disconnect — so a reservation can never leak
      // into the shared budget.
      if (budget != null && total > 0) {
        budget.release(total);
      }
    }
    return builder.takeBytes();
  }
}

/// Shared byte budget for all in-flight inbound request bodies.
///
/// A plain int is safe here without locks or atomics: Dart's event loop runs
/// a single isolate single-threaded, so each [tryReserve]/[release] pair
/// executes without interleaving with another.
class InboundBodyBudget {
  InboundBodyBudget({this.maxBytes = InboundLimits.maxInFlightBodyBytes});

  /// The cap on concurrently held bytes.
  final int maxBytes;

  int _inFlightBytes = 0;

  /// Reserves [bytes] against [maxBytes] and returns true, or returns false
  /// (reserving nothing) when the budget is exhausted.
  bool tryReserve(int bytes) {
    if (_inFlightBytes + bytes > maxBytes) return false;
    _inFlightBytes += bytes;
    return true;
  }

  /// Returns [bytes] to the budget. Must be called exactly once per
  /// successful [tryReserve], typically from a `finally` block.
  void release(int bytes) {
    _inFlightBytes -= bytes;
  }

  /// Bytes currently held by in-flight bodies (test seam).
  @visibleForTesting
  int get inFlightBytes => _inFlightBytes;
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

/// Thrown when the shared in-flight body budget ([InboundBodyBudget]) is
/// exhausted: many concurrent bodies are being held, so this connection is
/// refused even though its own body is within [PayloadTooLargeException]'s
/// per-body cap.
///
/// Callers map this to HTTP 503 — not 413, which would falsely tell an
/// honest client its message is too big.
class ServerBusyException implements Exception {
  @override
  String toString() =>
      'ServerBusyException: in-flight body budget exhausted';
}
