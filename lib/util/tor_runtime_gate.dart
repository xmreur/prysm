/// Gates outbound Tor traffic during restart/shutdown.
class TorRuntimeGate {
  TorRuntimeGate._();

  static bool Function()? isTorStopped;

  static bool get blocked => isTorStopped?.call() ?? false;
}
