import 'package:flutter/material.dart';
import 'package:prysm/screens/pin_entry.dart';
import 'package:prysm/screens/passphrase_entry.dart';
import 'package:prysm/services/biometric_unlock_service.dart';

/// Routes to [PinScreen] or [PassphraseScreen] based on [usePin].
class UnlockScreen extends StatefulWidget {
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
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  bool _biometricAttempted = false;
  bool _biometricUnlocking = false;
  bool _showBiometricButton = false;
  bool _initialBiometricCheckDone = false;

  @override
  void initState() {
    super.initState();
    _initBiometricUnlock();
  }

  Future<void> _initBiometricUnlock() async {
    final unlockSet = await widget.isUnlockSet;
    if (!mounted) return;

    if (!unlockSet) {
      setState(() => _initialBiometricCheckDone = true);
      return;
    }

    final canAttempt =
        await BiometricUnlockService.instance.canAttemptUnlock();
    if (!mounted) return;

    if (canAttempt && !_biometricAttempted) {
      _biometricAttempted = true;
      await _tryBiometricUnlock();
      return;
    }

    setState(() {
      _showBiometricButton = canAttempt;
      _initialBiometricCheckDone = true;
    });
  }

  Future<void> _tryBiometricUnlock() async {
    if (_biometricUnlocking) return;
    setState(() {
      _biometricUnlocking = true;
      _initialBiometricCheckDone = true;
      _showBiometricButton = true;
    });

    final secret =
        await BiometricUnlockService.instance.unlockWithBiometrics();
    if (!mounted) return;

    if (secret != null) {
      final ok = await widget.onVerify(secret);
      if (!mounted) return;
      if (!ok) {
        setState(() => _biometricUnlocking = false);
      }
      return;
    }

    setState(() => _biometricUnlocking = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialBiometricCheckDone || _biometricUnlocking) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                'Unlocking…',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    if (widget.usePin) {
      return PinScreen(
        onVerifyPin: widget.onVerify,
        isPinSet: widget.isUnlockSet,
        torBootstrapProgress: widget.torBootstrapProgress,
        showBiometricButton: _showBiometricButton,
        onTryBiometric: _tryBiometricUnlock,
      );
    }
    return PassphraseScreen(
      onVerifyPassphrase: widget.onVerify,
      isPassphraseSet: widget.isUnlockSet,
      torBootstrapProgress: widget.torBootstrapProgress,
      showBiometricButton: _showBiometricButton,
      onTryBiometric: _tryBiometricUnlock,
    );
  }
}
