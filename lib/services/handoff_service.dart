import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
/// Post-restore crypto re-init for account transfer.
///
/// A transfer export wipes the source immediately, so the backup is
/// quiescent by construction and a plain restore suffices. For any other
/// restore (older backup, source kept alive too long), replaying stale
/// Double-Ratchet state reuses message keys the peer already saw. This
/// re-init drops all 1:1 sessions (next message bootstraps a fresh X3DH)
/// and refreshes the one-time pool (reuse is forbidden by X3DH). The signed
/// prekey is kept: it has no rotation schedule and peers already hold it.
///
/// Group epochs are intentionally left alone: a stale outbound send is
/// ack-dropped idempotently by recipients, and the next natural rotation
/// heals it. Proactive rotation needs network + admin rights per group —
/// see the map (`Not yet specified`) if that trade-off is ever revisited.
// ponytail: local-only re-init; group rotation stays on natural triggers.
class HandoffService {
  HandoffService._();

  static Future<void> reinitCryptoForHandoff({
    required KeyManager keyManager,
  }) async {
    final db = await DBHelper.database;
    await RatchetSessionStore(db).deleteAll();
    await CryptoKeyStore.delete(PrekeyBundle.storageOneTimePreKeyPool);
    await CryptoKeyStore.delete(PrekeyBundle.storageOneTimePreKeyPrivate);
    await PrekeyBundle.loadStored(keyManager.identity);
  }
}
