import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/tor_service.dart';

/// Deprecated alias for [TransportProvider]. Prefer [TransportProvider] directly.
class TorOutboundGateway {
  TorOutboundGateway._();

  static bool get isConfigured => TransportProvider.isConfigured;

  static TransportProvider get instance => TransportProvider.instance;

  static void configure(TorManager torManager) {
    TransportProvider.configure(torManager);
  }

  static void resetForTest() {
    TransportProvider.resetForTest();
  }
}
