/// Determines which peer opens the outbound WebSocket for a pair.
bool shouldDialPeer({
  required String localOnion,
  required String peerOnion,
}) =>
    localOnion.compareTo(peerOnion) < 0;
