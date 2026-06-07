import 'dart:async';

import 'package:prysm/services/reaction_service.dart';

/// Broadcasts reaction changes so open chat screens can refresh UI.
class ReactionRefreshNotifier {
  ReactionRefreshNotifier._();
  static final ReactionRefreshNotifier instance = ReactionRefreshNotifier._();

  final _controller = StreamController<ReactionUpdate>.broadcast();

  Stream<ReactionUpdate> get onReactionChanged => _controller.stream;

  void notify(ReactionUpdate update) {
    if (!_controller.isClosed) {
      _controller.add(update);
    }
  }
}
