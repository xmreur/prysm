/// Message statuses used for inbound authentication gating.
class MessageAuthStatus {
  MessageAuthStatus._();

  static const String received = 'received';
  static const String pendingAuth = 'pending_auth';
  static const String quarantined = 'quarantined';

  static bool isUndisplayable(String? status) =>
      status == pendingAuth || status == quarantined;
}
