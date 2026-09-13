import 'protocol.dart';

/// A protocol-level failure carrying a code from [RelayErrorCode].
///
/// Named `RelayError` and not `...Exception` because both sides treat it as the
/// wire's error value: the server serialises it, the client switches on it.
class RelayError implements Exception {
  final String code;
  final String message;

  const RelayError(this.code, this.message);

  factory RelayError.badRequest(String message) =>
      RelayError(RelayErrorCode.badRequest, message);

  int get httpStatus => RelayErrorCode.httpStatus(code);

  bool get retryable => RelayErrorCode.isRetryable(code);

  Map<String, dynamic> toJson() => {'error': code, 'message': message};

  static RelayError fromJson(Map<String, dynamic> json) => RelayError(
        json['error'] as String? ?? RelayErrorCode.internal,
        json['message'] as String? ?? '',
      );

  @override
  String toString() => 'RelayError($code): $message';
}
