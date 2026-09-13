/// One implementation of "tighten this path's mode", shared by the identity
/// file and the data dir.
///
/// Dart has no `chmod` binding, so this shells out — and a failure is fatal,
/// not cosmetic: the paths it guards hold the relay's signing seeds and its
/// bearer tokens. Refusing to continue is the whole point.
library;

import 'dart:io';

Future<void> restrictPath(String path, String mode) async {
  // Windows has no POSIX mode bits; ACLs there are the operator's business.
  if (Platform.isWindows) return;
  final ProcessResult result;
  try {
    result = await Process.run('chmod', [mode, path]);
  } on ProcessException catch (e) {
    throw StateError('cannot run chmod $mode $path: ${e.message}');
  }
  if (result.exitCode != 0) {
    throw StateError(
      'chmod $mode $path failed with exit ${result.exitCode}: '
      '${result.stderr}'.trim(),
    );
  }
}
