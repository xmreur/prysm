import 'package:flutter/material.dart';
import 'package:prysm/services/panic_wipe_service.dart';
import 'package:prysm/util/key_manager.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Local data error',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              const Text(
                'Prysm could not open its local database. This can happen after '
                'an interrupted update or corrupted storage.',
              ),
              const SizedBox(height: 12),
              Text(
                error,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _resetLocalData(context),
                child: const Text('Reset local data and continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
