import 'package:flutter/material.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:prysm/util/download_location.dart';

/// Shows the create-backup password dialog and writes an encrypted backup file.
/// Returns true when a backup file was written successfully.
Future<bool> showCreateBackupDialog(BuildContext context) async {
  final passwordController = TextEditingController();
  var created = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Create Backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose a strong password to encrypt your backup. '
            'You will need this password to restore.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Backup Password',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            final password = passwordController.text;
            if (password.length < 4) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(
                  content: Text('Password must be at least 4 characters'),
                ),
              );
              return;
            }
            final messenger = ScaffoldMessenger.of(context);
            Navigator.pop(dialogContext);
            created = await performBackup(messenger, password);
          },
          child: const Text('Create Backup'),
        ),
      ],
    ),
  );
  passwordController.dispose();
  return created;
}

/// Creates an encrypted backup in the user's download folder.
Future<bool> performBackup(
  ScaffoldMessengerState messenger,
  String password,
) async {
  try {
    final fileName =
        'prysm_backup_${DateTime.now().millisecondsSinceEpoch}.prysmbackup';
    final file = await DownloadLocation.uniqueFile(fileName);
    await BackupService.createBackup(file.path, password);

    messenger.showSnackBar(
      SnackBar(
        content: Text('Backup saved to ${file.path}'),
        duration: const Duration(seconds: 5),
      ),
    );
    return true;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Backup failed: $e')),
    );
    return false;
  }
}
