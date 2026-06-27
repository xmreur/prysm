import 'dart:async';

/// Tracks who is currently typing in each conversation with auto-expiry.
class TypingStateTracker {
  static const _expiryDuration = Duration(seconds: 5);

  final Map<String, Map<String, DateTime>> _lastSeenByConversation = {};
  final Map<String, Map<String, Timer>> _expiryTimersByConversation = {};
  final _changeController = StreamController<void>.broadcast();

  Stream<void> get onChanged => _changeController.stream;

  List<String> activeTypists(String conversationKey) {
    final typists = _lastSeenByConversation[conversationKey];
    if (typists == null || typists.isEmpty) return const [];

    final now = DateTime.now();
    return typists.entries
        .where((entry) => now.difference(entry.value) < _expiryDuration)
        .map((entry) => entry.key)
        .toList()
      ..sort();
  }

  void applyEvent({
    required String conversationKey,
    required String senderId,
    required bool typing,
    required int timestamp,
  }) {
    if (conversationKey.isEmpty || senderId.isEmpty) return;

    final typists =
        _lastSeenByConversation.putIfAbsent(conversationKey, () => {});
    final timers =
        _expiryTimersByConversation.putIfAbsent(conversationKey, () => {});

    if (!typing) {
      typists.remove(senderId);
      timers.remove(senderId)?.cancel();
      _notify();
      return;
    }

    typists[senderId] = DateTime.fromMillisecondsSinceEpoch(timestamp);
    timers.remove(senderId)?.cancel();
    timers[senderId] = Timer(_expiryDuration, () {
      typists.remove(senderId);
      timers.remove(senderId);
      _notify();
    });
    _notify();
  }

  void clearConversation(String conversationKey) {
    final timers = _expiryTimersByConversation.remove(conversationKey);
    if (timers != null) {
      for (final timer in timers.values) {
        timer.cancel();
      }
    }
    _lastSeenByConversation.remove(conversationKey);
    _notify();
  }

  void dispose() {
    for (final timers in _expiryTimersByConversation.values) {
      for (final timer in timers.values) {
        timer.cancel();
      }
    }
    _expiryTimersByConversation.clear();
    _lastSeenByConversation.clear();
    unawaited(_changeController.close());
  }

  void _notify() {
    if (!_changeController.isClosed) {
      _changeController.add(null);
    }
  }
}
