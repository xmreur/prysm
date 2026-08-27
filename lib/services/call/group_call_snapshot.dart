import 'package:prysm/models/group.dart';
import 'package:prysm/services/call/call_manager.dart';

/// One roster row as the call cares about it: who, what they may do, and
/// whether moderation has muted them.
class GroupCallMember {
  const GroupCallMember({
    required this.onion,
    required this.role,
    required this.muted,
  });

  final String onion;
  final GroupRole role;
  final bool muted;
}

/// Immutable view of a group call, consumed by the overlay, the group chat
/// banner and the tray.
class GroupCallSnapshot {
  const GroupCallSnapshot({
    required this.state,
    this.groupId,
    this.callId,
    this.members = const [],
    this.joined = const {},
    this.peerMuted = const {},
    this.localMuted = false,
    this.listenOnly = false,
    this.dismissed = false,
    this.error,
    this.activeSince,
  });

  final CallState state;
  final String? groupId;
  final String? callId;

  /// Frozen participant order from the offer; also the nonce slot order.
  final List<String> members;
  final Set<String> joined;

  /// Per-participant call mute (`group_call_mute`), not moderation mute.
  final Map<String, bool> peerMuted;
  final bool localMuted;

  /// Moderation muted us: capture stays off and mute cannot be toggled.
  final bool listenOnly;

  /// The ring was dismissed. The overlay hides, the join banner stays.
  final bool dismissed;
  final String? error;
  final DateTime? activeSince;

  bool get isInCall =>
      !dismissed &&
      (state == CallState.connecting ||
          state == CallState.ringing ||
          state == CallState.incoming ||
          state == CallState.active);

  /// A call is live in this group and we are not in it.
  bool get showJoinBanner => dismissed && callId != null && groupId != null;

  bool showJoinBannerFor(String groupId) =>
      showJoinBanner && this.groupId == groupId;

  /// `CallForegroundSession` speaks 1:1 snapshots; the group id stands in for
  /// the peer so wakelock, ringtone and notifications work unchanged.
  CallSnapshot get asCallSnapshot => CallSnapshot(
        state: dismissed ? CallState.idle : state,
        peerOnion: groupId,
        callId: callId,
        localMuted: localMuted,
        peerMuted: peerMuted.values.any((muted) => muted),
        error: error,
        activeSince: activeSince,
      );

  GroupCallSnapshot copyWith({
    CallState? state,
    Set<String>? joined,
    Map<String, bool>? peerMuted,
    bool? localMuted,
    bool? listenOnly,
    DateTime? activeSince,
  }) {
    return GroupCallSnapshot(
      state: state ?? this.state,
      groupId: groupId,
      callId: callId,
      members: members,
      joined: joined ?? this.joined,
      peerMuted: peerMuted ?? this.peerMuted,
      localMuted: localMuted ?? this.localMuted,
      listenOnly: listenOnly ?? this.listenOnly,
      dismissed: dismissed,
      activeSince: activeSince ?? this.activeSince,
    );
  }
}
