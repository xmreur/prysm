import 'package:prysm/util/voice_player.dart';

/// Ensures only one voice message plays at a time in a chat list.
class VoicePlaybackCoordinator {
  VoicePlaybackCoordinator._();
  static final VoicePlaybackCoordinator instance = VoicePlaybackCoordinator._();

  String? _activeMessageId;
  VoicePlayer? _activePlayer;

  Future<void> requestPlay({
    required String messageId,
    required VoicePlayer player,
  }) async {
    if (_activeMessageId != null &&
        _activeMessageId != messageId &&
        _activePlayer != null) {
      try {
        await _activePlayer!.stop();
      } catch (_) {}
    }
    _activeMessageId = messageId;
    _activePlayer = player;
  }

  void release(String messageId, VoicePlayer player) {
    if (_activeMessageId == messageId && _activePlayer == player) {
      _activeMessageId = null;
      _activePlayer = null;
    }
  }
}
