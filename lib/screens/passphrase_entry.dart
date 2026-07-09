import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/screens/widgets/unlock_lockout_banner.dart';
import 'package:prysm/services/unlock_lockout_service.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

class PassphraseScreen extends StatefulWidget {
  final Future<bool> Function(String passphrase) onVerifyPassphrase;
  final Future<bool> isPassphraseSet;
  final int? torBootstrapProgress;
  final bool showBiometricButton;
  final VoidCallback? onTryBiometric;

  const PassphraseScreen({
    required this.onVerifyPassphrase,
    required this.isPassphraseSet,
    this.torBootstrapProgress,
    this.showBiometricButton = false,
    this.onTryBiometric,
    super.key,
  });

  @override
  State<PassphraseScreen> createState() => _PassphraseScreenState();
}

class _PassphraseScreenState extends State<PassphraseScreen> {
  final _controller = TextEditingController();
  final _confirmController = TextEditingController();
  String? error;
  bool isLoading = false;
  bool obscure = true;
  bool? _passphraseAlreadySet;
  bool _isConfirmingSetup = false;
  bool _lastFailure = false;
  bool _lockedOut = false;

  @override
  void initState() {
    super.initState();
    widget.isPassphraseSet.then((set) {
      if (mounted) setState(() => _passphraseAlreadySet = set);
    });
    _refreshLockout();
  }

  Future<void> _refreshLockout() async {
    final locked = await UnlockLockoutService.instance.isLockedOut();
    if (mounted) setState(() => _lockedOut = locked);
  }

  @override
  void dispose() {
    _controller.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  bool get _isSetup => _passphraseAlreadySet == false;

  String get _title {
    if (_passphraseAlreadySet == null) return '';
    if (_isConfirmingSetup) return 'Confirm Passphrase';
    if (_isSetup) return 'Create Passphrase';
    return 'Enter Passphrase';
  }

  Future<void> _submit(String passphrase) async {
    setState(() {
      isLoading = true;
      error = null;
    });

    final success = await widget.onVerifyPassphrase(passphrase);
    if (!mounted) return;

    if (!success) {
      await _refreshLockout();
      setState(() {
        error = _isSetup
            ? 'Could not set up passphrase. Use at least 12 characters.'
            : 'Incorrect passphrase';
        isLoading = false;
        _lastFailure = !_isSetup;
      });
      return;
    }

    setState(() {
      error = null;
      isLoading = false;
      _lastFailure = false;
    });
  }

  void _onSubmitPressed() {
    if (_lockedOut && !_isSetup) return;

    final value = _controller.text;
    if (_isSetup) {
      if (value.length < 12) {
        setState(() => error = 'Passphrase must be at least 12 characters');
        return;
      }
    } else if (value.isEmpty) {
      setState(() => error = 'Enter passphrase or panic PIN');
      return;
    }

    if (_isSetup) {
      if (!_isConfirmingSetup) {
        setState(() {
          _isConfirmingSetup = true;
          error = null;
        });
        return;
      }
      if (value != _confirmController.text) {
        setState(() {
          error = 'Passphrases do not match';
          _isConfirmingSetup = false;
          _confirmController.clear();
        });
        return;
      }
    }

    _submit(value);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final inputDisabled = _lockedOut && !_isSetup;

    return ColoredBox(
      color: tokens.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _title,
                    style: context.prysmStyle.headlineStyle,
                  ),
                  if (widget.showBiometricButton &&
                      !_isSetup &&
                      widget.onTryBiometric != null) ...[
                    const SizedBox(height: 16),
                    PrysmIconButton(
                      icon: PrysmIcons.fingerprint,
                      tooltip: 'Unlock with biometrics',
                      onPressed: widget.onTryBiometric,
                    ),
                  ],
                  if (_isSetup) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Minimum 12 characters',
                      style: context.prysmStyle.captionStyle,
                    ),
                  ],
                  const SizedBox(height: 24),
                  PrysmTextField(
                    controller:
                        _isConfirmingSetup ? _confirmController : _controller,
                    labelText: _isConfirmingSetup
                        ? 'Confirm passphrase'
                        : 'Passphrase',
                    obscureText: obscure,
                    enabled: !inputDisabled,
                    suffixIcon: PrysmIconButton(
                      icon: obscure
                          ? PrysmIcons.visibility
                          : PrysmIcons.visibilityOff,
                      onPressed: () => setState(() => obscure = !obscure),
                    ),
                    onSubmitted: (_) => _onSubmitPressed(),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(color: tokens.danger),
                    ),
                  ],
                  UnlockLockoutStatus(
                    showAttemptsRemaining: !_isSetup,
                    lastFailure: _lastFailure,
                  ),
                  const SizedBox(height: 24),
                  if (isLoading)
                    const PrysmProgressIndicator()
                  else
                    PrysmButton(
                      label: _isSetup ? 'Continue' : 'Unlock',
                      onPressed: inputDisabled ? null : _onSubmitPressed,
                    ),
                  if (widget.torBootstrapProgress != null) ...[
                    const SizedBox(height: 16),
                    Text('Tor: ${widget.torBootstrapProgress}%'),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal passphrase prompt for settings flows (change passphrase, etc.).
Future<String?> showPassphraseDialog({
  required BuildContext context,
  required String title,
  required String subtitle,
  bool confirm = false,
  int minLength = 12,
  Future<String?> Function(String value)? validate,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: const Color(0x80000000),
    pageBuilder: (context, animation, secondaryAnimation) {
      return Center(
        child: _PassphraseDialog(
          title: title,
          subtitle: subtitle,
          confirm: confirm,
          minLength: minLength,
          validate: validate,
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.title,
    required this.subtitle,
    required this.confirm,
    required this.minLength,
    this.validate,
  });

  final String title;
  final String subtitle;
  final bool confirm;
  final int minLength;
  final Future<String?> Function(String value)? validate;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _controller = TextEditingController();
  final _confirmController = TextEditingController();
  var _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _controller.text;
    if (value.length < widget.minLength) {
      setState(
        () => _error = 'Must be at least ${widget.minLength} characters',
      );
      return;
    }
    if (widget.confirm && value != _confirmController.text) {
      setState(() => _error = 'Passphrases do not match');
      return;
    }
    if (widget.validate != null) {
      final validationError = await widget.validate!(value);
      if (!mounted) return;
      if (validationError != null) {
        setState(() => _error = validationError);
        return;
      }
    }
    if (mounted) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return PrysmDialog(
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.subtitle),
          const SizedBox(height: 12),
          PrysmTextField(
            controller: _controller,
            labelText: 'Passphrase',
            obscureText: _obscure,
            suffixIcon: PrysmIconButton(
              icon: _obscure ? PrysmIcons.visibility : PrysmIcons.visibilityOff,
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 8),
            PrysmTextField(
              controller: _confirmController,
              labelText: 'Confirm passphrase',
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: tokens.danger)),
          ],
        ],
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Continue',
      onConfirm: _submit,
    );
  }
}
