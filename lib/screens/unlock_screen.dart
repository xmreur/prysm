import 'package:flutter/material.dart';
import 'package:prysm/screens/pin_entry.dart';
import 'package:prysm/screens/passphrase_entry.dart';

/// Routes to [PinScreen] or [PassphraseScreen] based on [usePin].
class UnlockScreen extends StatelessWidget {
  const UnlockScreen({
    required this.usePin,
    required this.onVerify,
    required this.isUnlockSet,
    this.torBootstrapProgress,
    super.key,
  });

  final bool usePin;
  final Future<bool> Function(String secret) onVerify;
  final Future<bool> isUnlockSet;
  final int? torBootstrapProgress;

  @override
  Widget build(BuildContext context) {
    if (usePin) {
      return PinScreen(
        onVerifyPin: onVerify,
        isPinSet: isUnlockSet,
        torBootstrapProgress: torBootstrapProgress,
      );
    }
    return PassphraseScreen(
      onVerifyPassphrase: onVerify,
      isPassphraseSet: isUnlockSet,
      torBootstrapProgress: torBootstrapProgress,
    );
  }
}
