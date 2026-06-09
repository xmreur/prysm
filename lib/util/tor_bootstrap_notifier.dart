import 'dart:async';

/// Tor bootstrap progress (0–100) for splash / PIN screen.
class TorBootstrapNotifier {
  TorBootstrapNotifier._();
  static final TorBootstrapNotifier instance = TorBootstrapNotifier._();

  final _controller = StreamController<int>.broadcast();
  int _progress = 0;

  Stream<int> get onProgress => _controller.stream;
  int get progress => _progress;

  void update(int percent) {
    final clamped = percent.clamp(0, 100);
    if (clamped == _progress) return;
    _progress = clamped;
    if (!_controller.isClosed) {
      _controller.add(_progress);
    }
  }

  void reset() {
    _progress = 0;
    if (!_controller.isClosed) {
      _controller.add(0);
    }
  }
}
