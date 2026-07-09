import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:prysm/util/download_location.dart';

/// Shows the create-backup password dialog and writes an encrypted backup file.
/// Returns true when a backup file was written successfully.
Future<bool> showCreateBackupDialog(BuildContext context) async {
  final passwordController = TextEditingController();
  var created = false;
  await showPrysmDialog<void>(
    context: context,
    title: 'Create Backup',
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
        PrysmTextField(
          controller: passwordController,
          labelText: 'Backup Password',
          obscureText: true,
          prefixIcon: const Icon(PrysmIcons.lock),
        ),
      ],
    ),
    cancelLabel: 'Cancel',
    confirmLabel: 'Create Backup',
    onConfirm: () async {
      final password = passwordController.text;
      if (password.length < 4) {
        showPrysmToast(context, 'Password must be at least 4 characters');
        return;
      }
      Navigator.pop(context);
      created = await performBackup(context, password);
    },
  );
  passwordController.dispose();
  return created;
}

/// Creates an encrypted backup in the user's download folder.
Future<bool> performBackup(BuildContext context, String password) async {
  try {
    final fileName =
        'prysm_backup_${DateTime.now().millisecondsSinceEpoch}.prysmbackup';
    final file = await DownloadLocation.uniqueFile(fileName);
    await BackupService.createBackup(file.path, password);

    if (!context.mounted) return false;
    showPrysmToast(context, 'Backup saved to ${file.path}');
    return true;
  } catch (e) {
    if (!context.mounted) return false;
    showPrysmToast(context, 'Backup failed: $e');
    return false;
  }
}
