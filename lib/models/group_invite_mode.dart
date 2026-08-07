/// What happens to a group invite whose sender's identity is not in the
/// local user store.
///
/// The security boundary is the same in both modes: the sender is never
/// resolved over the network on an inbound message (M2). The choice is only
/// whether the invite is kept for the user to decide on, or dropped.
enum GroupInviteMode {
  holdAsRequest,
  contactsOnly;

  String get label => switch (this) {
        GroupInviteMode.holdAsRequest => 'Hold invites from unknown senders',
        GroupInviteMode.contactsOnly => 'Only accept invites from contacts',
      };

  String get description => switch (this) {
        GroupInviteMode.holdAsRequest =>
          'An invite from someone who is not in your contacts is kept as a '
              "request. Your device never contacts them, and you don't join "
              'the group until you accept.',
        GroupInviteMode.contactsOnly =>
          'Invites from anyone else are discarded the moment they arrive: '
              'nothing is stored, nothing is shown.',
      };

  static GroupInviteMode fromJson(String? value) {
    return GroupInviteMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => GroupInviteMode.holdAsRequest,
    );
  }
}
