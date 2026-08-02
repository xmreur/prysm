import 'package:prysm/models/shared_content.dart';

/// Holds an OS share payload until [HomeScreen] can show the chat picker.
class PendingShareStore {
  PendingShareStore._();

  static final PendingShareStore instance = PendingShareStore._();

  SharedContent? _pending;

  void set(SharedContent? content) {
    _pending = content;
  }

  SharedContent? peek() => _pending;

  SharedContent? take() {
    final content = _pending;
    _pending = null;
    return content;
  }

  void clear() {
    _pending = null;
  }
}
