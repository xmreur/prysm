import 'package:flutter/widgets.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';

/// Shown when local database initialization fails at startup.
class StartupFatalErrorScreen extends StatelessWidget {
  const StartupFatalErrorScreen({
    required this.error,
    required this.keyManager,
    required this.onResetComplete,
    super.key,
  });

  final String error;
  final KeyManager keyManager;
  final VoidCallback onResetComplete;

  Future<void> _resetLocalData(BuildContext context) async {
    await PanicWipeService.wipeAll();
    await keyManager.wipeSecureStorage();
    if (context.mounted) onResetComplete();
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
                'Local data error',
                style: context.prysmStyle.headlineStyle,
              ),
              const SizedBox(height: 16),
              const Text(
                'Prysm could not open its local database. This can happen after '
                'an interrupted update or corrupted storage.',
              ),
              const SizedBox(height: 12),
              Text(
                error,
                style: context.prysmStyle.captionStyle,
              ),
              const Spacer(),
              PrysmButton(
                label: 'Reset local data and continue',
                onPressed: () => _resetLocalData(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
