/// Builds Tor hidden-service profile URLs with optional requester identity.
class ProfileHttpUri {
  ProfileHttpUri._();

  static Uri build(String peerOnion, {String? requesterOnion}) {
    final query = <String, String>{};
    if (requesterOnion != null && requesterOnion.isNotEmpty) {
      query['requester'] = requesterOnion;
    }
    return Uri(
      scheme: 'http',
      host: peerOnion,
      port: 80,
      path: '/profile',
      queryParameters: query.isEmpty ? null : query,
    );
  }
}
