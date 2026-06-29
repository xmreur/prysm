import 'package:flutter/material.dart';

class PassphraseScreen extends StatefulWidget {
  final Future<bool> Function(String passphrase) onVerifyPassphrase;
  final Future<bool> isPassphraseSet;
  final int? torBootstrapProgress;

  const PassphraseScreen({
    required this.onVerifyPassphrase,
    required this.isPassphraseSet,
    this.torBootstrapProgress,
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

  @override
  void initState() {
    super.initState();
    widget.isPassphraseSet.then((set) {
      if (mounted) setState(() => _passphraseAlreadySet = set);
    });
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
      setState(() {
        error = _isSetup
            ? 'Could not set up passphrase. Use at least 12 characters.'
            : 'Incorrect passphrase';
        isLoading = false;
      });
      return;
    }

    setState(() {
      error = null;
      isLoading = false;
    });
  }

  void _onSubmitPressed() {
    final value = _controller.text;
    if (value.length < 12) {
      setState(() => error = 'Passphrase must be at least 12 characters');
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
    final field = TextField(
      controller: _isConfirmingSetup ? _confirmController : _controller,
      obscureText: obscure,
      autofocus: true,
      onSubmitted: (_) => _onSubmitPressed(),
      decoration: InputDecoration(
        labelText: _isConfirmingSetup ? 'Confirm passphrase' : 'Passphrase',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: () => setState(() => obscure = !obscure),
        ),
      ),
    );

    return Scaffold(
      body: SafeArea(
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
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Minimum 12 characters',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  field,
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (isLoading)
                    const CircularProgressIndicator()
                  else
                    FilledButton(
                      onPressed: _onSubmitPressed,
                      child: Text(_isSetup ? 'Continue' : 'Unlock'),
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
  Future<String?> Function(String value)? validate,
}) async {
  final controller = TextEditingController();
  final confirmController = TextEditingController();
  var obscure = true;
  String? error;

  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> submit() async {
            final value = controller.text;
            if (value.length < 12) {
              setState(() => error = 'Passphrase must be at least 12 characters');
              return;
            }
            if (confirm && value != confirmController.text) {
              setState(() => error = 'Passphrases do not match');
              return;
            }
            if (validate != null) {
              final validationError = await validate(value);
              if (validationError != null) {
                setState(() => error = validationError);
                return;
              }
            }
            if (context.mounted) Navigator.pop(context, value);
          }

          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(subtitle),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: obscure,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Passphrase',
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => setState(() => obscure = !obscure),
                    ),
                  ),
                  onSubmitted: (_) => submit(),
                ),
                if (confirm) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmController,
                    obscureText: obscure,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Confirm passphrase',
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Continue'),
              ),
            ],
          );
        },
      );
    },
  );

  controller.dispose();
  confirmController.dispose();
  return result;
}
