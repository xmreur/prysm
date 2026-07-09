import 'package:flutter/widgets.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';

/// Shown once when upgrading from legacy crypto to v2.
class CryptoMigrationScreen extends StatelessWidget {
  const CryptoMigrationScreen({
    required this.keyManager,
    required this.onComplete,
    super.key,
  });

  final KeyManager keyManager;
  final VoidCallback onComplete;

  Future<void> _wipe(BuildContext context) async {
    await PanicWipeService.wipeAll();
    await keyManager.wipeSecureStorage();
    if (context.mounted) onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return ColoredBox(
      color: tokens.background,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Crypto upgrade required',
                style: context.prysmStyle.headlineStyle,
              ),
              const SizedBox(height: 16),
              const Text(
                'Prysm 0.3 uses new end-to-end encryption (Curve25519 + AEAD). '
                'Existing messages, contacts, and keys from 0.2.x cannot be migrated automatically.\n\n'
                'All peers must upgrade. You will need to re-add contacts via QR after setup.',
              ),
              const Spacer(),
              PrysmButton(
                label: 'Wipe local data and continue',
                onPressed: () => _wipe(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
