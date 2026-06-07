import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/services/backup_service.dart';

/// Shows the create-backup password dialog and writes an encrypted backup file.
Future<void> showCreateBackupDialog(BuildContext context) async {
  final passwordController = TextEditingController();
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
            Navigator.pop(dialogContext);
            if (!context.mounted) return;
            await performBackup(context, password);
          },
          child: const Text('Create Backup'),
        ),
      ],
    ),
  );
  passwordController.dispose();
}

/// Creates an encrypted backup at Documents/prysm_backups/.
Future<bool> performBackup(BuildContext context, String password) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(dir.path, 'prysm_backups'));
    if (!await backupDir.exists()) await backupDir.create(recursive: true);
    final fileName =
        'prysm_backup_${DateTime.now().millisecondsSinceEpoch}.prysmbackup';
    final outputPath = p.join(backupDir.path, fileName);
    await BackupService.createBackup(outputPath, password);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Backup saved to ${backupDir.path}/$fileName'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: $e')),
      );
    }
    return false;
  }
}
