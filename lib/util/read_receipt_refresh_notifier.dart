import 'dart:async';

import 'package:prysm/services/read_receipt_service.dart';

/// Broadcasts read receipt changes so open chat screens can refresh tick UI.
class ReadReceiptRefreshNotifier {
  ReadReceiptRefreshNotifier._();
  static final ReadReceiptRefreshNotifier instance =
      ReadReceiptRefreshNotifier._();

  final _controller = StreamController<ReadReceiptUpdate>.broadcast();

  Stream<ReadReceiptUpdate> get onReadReceiptChanged => _controller.stream;

  void notify(ReadReceiptUpdate update) {
    if (!_controller.isClosed) {
      _controller.add(update);
    }
  }
}
