import 'package:flutter/foundation.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';

/// Gates outbound Tor traffic during restart/shutdown.
class TorRuntimeGate {
  TorRuntimeGate._();

  static bool Function()? isTorStopped;

  static bool get blocked {
    if (TorLifecycleNotifier.instance.blocked) return true;
    return isTorStopped?.call() ?? false;
  }

  @visibleForTesting
  static void resetForTest({
    TorLifecycleState lifecycle = TorLifecycleState.ready,
  }) {
    isTorStopped = null;
    TorLifecycleNotifier.instance.update(lifecycle);
  }
}
