import 'dart:async';

/// Fired when the local user is removed from a group and it was purged locally.
class GroupMembershipNotifier {
  GroupMembershipNotifier._();
  static final GroupMembershipNotifier instance = GroupMembershipNotifier._();

  final _controller = StreamController<String>.broadcast();

  Stream<String> get onRemoved => _controller.stream;

  void notifyRemoved(String groupId) {
    if (!_controller.isClosed) {
      _controller.add(groupId);
    }
  }
}
