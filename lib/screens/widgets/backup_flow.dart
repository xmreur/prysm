import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/services/backup_service.dart';
import 'package:prysm/util/download_location.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

/// Shows the create-backup password dialog and writes an encrypted backup file.
/// Returns true when a backup file was written successfully.
Future<bool> showCreateBackupDialog(BuildContext context) async {
  final passwordController = TextEditingController();
  var created = false;
  await showPrysmDialog<void>(
    context: context,
    title: context.l10n.createBackup,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${context.l10n.chooseAStrongPasswordToEncryptYourBackup}'
          '${context.l10n.youWillNeedThisPasswordToRestore}',
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 16),
        PrysmTextField(
          controller: passwordController,
          labelText: context.l10n.backupPassword,
          obscureText: true,
          prefixIcon: const Icon(PrysmIcons.lock),
        ),
      ],
    ),
    cancelLabel: context.l10n.cancel,
    confirmLabel: context.l10n.createBackup,
    onConfirm: () async {
      final password = passwordController.text;
      if (password.length < 4) {
        showPrysmToast(context, context.l10n.passwordMustBeAtLeast4Characters);
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
    showPrysmToast(context, context.l10n.backupSavedTo(file.path));
    return true;
  } catch (e) {
    if (!context.mounted) return false;
    showPrysmToast(context, context.l10n.backupFailedE(e.toString()));
    return false;
  }
}
