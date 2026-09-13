/// The 60 s sweeper: deletes expired items, drops used/expired tokens.
library;

import 'log.dart';
import 'store.dart';

class SweepResult {
  const SweepResult({required this.expiredItems, required this.droppedTokens});

  final int expiredItems;
  final int droppedTokens;
}

Future<SweepResult> sweepStore(
  RelayStore store, {
  required int nowMs,
  RelayLog? log,
}) async {
  final expiredItems = await store.deleteExpiredItems(nowMs);
  final droppedTokens = await store.pruneTokens(nowMs);
  if (log != null && (expiredItems > 0 || droppedTokens > 0)) {
    log.event(
      'sweep: expiredItems=$expiredItems droppedTokens=$droppedTokens',
    );
  }
  return SweepResult(
    expiredItems: expiredItems,
    droppedTokens: droppedTokens,
  );
}
