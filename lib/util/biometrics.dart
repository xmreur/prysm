import 'dart:io';

import 'package:flutter/services.dart';

class Biometrics {
  Biometrics._();

  static const MethodChannel _channel =
      MethodChannel('com.xmreur.prysm/biometric');

  static Future<Map<String, dynamic>> canAuthenticate() async {
    if (!Platform.isAndroid) {
      return {
        'available': false,
        'code': 'UNSUPPORTED',
        'message': 'Biometrics not supported on this platform',
      };
    }
    final result = await _channel.invokeMethod<dynamic>('canAuthenticate');
    return Map<String, dynamic>.from(result as Map);
  }

  static Future<bool> get isAvailable async {
    final result = await canAuthenticate();
    return result['available'] == true;
  }

  static Future<Map<String, dynamic>> authenticate({
    required String title,
    String subtitle = '',
    String cancelText = 'Cancel',
  }) async {
    if (!Platform.isAndroid) {
      return {
        'success': false,
        'code': 'UNSUPPORTED',
        'message': 'Biometrics not supported on this platform',
      };
    }
    final result = await _channel.invokeMethod<dynamic>(
      'authenticate',
      {
        'title': title,
        'subtitle': subtitle,
        'cancelText': cancelText,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  static Future<bool> authenticateForUnlock() async {
    final result = await authenticate(
      title: 'Unlock Prysm',
      subtitle: 'Use your fingerprint or face',
      cancelText: 'Use passcode',
    );
    return result['success'] == true;
  }
}
