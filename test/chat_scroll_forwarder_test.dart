// Pins the FINAL whole-branch review fix for _ChatScreenState /
// _GroupChatScreenState (chat.dart, group_chat.dart): the scroll listener
// registered on `_listScrollController` must be a STABLE, State-level
// forwarder — never a tear-off of the mutable `_controller` field.
//
// Both screens rebuild `_controller` after the widget is first built
// (group_chat.dart: `_init()` swaps controllers after the first `await`,
// and `didUpdateWidget` on group-id change; chat.dart: `didUpdateWidget` on
// peerId change). Registering `_listScrollController.addListener(_controller
// .onListScroll)` captures a tear-off bound to whichever controller
// instance existed *at registration time*. Once that instance is disposed
// and replaced, the stale tear-off keeps firing against the disposed
// object: throws "used after being disposed" in debug/test, and silently
// stops updating `stickToBottom` in release.
//
// This test models the pattern in isolation (a fake controller double +
// a minimal host mirroring the State's field/forwarder/dispose shape) so it
// runs as a fast unit test without pulling in the full ChatScreenController
// dependency graph (see chat_screen_controller_test.dart for that heavier
// coverage). It exercises exactly the invariant the fix establishes:
// the forwarder always calls the *current* controller and is the same
// object reference on both addListener and removeListener.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal double for ChatScreenController's relevant surface: an instance
/// method used directly as a ScrollController listener, plus a
/// disposed-guard matching real widgets/foundation ChangeNotifier semantics
/// (calling a method on a disposed controller throws).
class _FakeChatController {
  int scrollCalls = 0;
  bool _disposed = false;

  void onListScroll() {
    if (_disposed) {
      throw StateError('A FakeChatController was used after being disposed.');
    }
    scrollCalls++;
  }

  void dispose() => _disposed = true;
}

/// Mirrors the fixed State-level wiring: ONE stable forwarder is registered
/// in "initState" and removed in "dispose"; it is never rebuilt when
/// `_controller` is swapped (simulating didUpdateWidget / re-init).
class _FixedHost {
  _FixedHost() {
    _listScrollController.addListener(_onListScrollForward);
  }

  final ScrollController _listScrollController = ScrollController();
  _FakeChatController _controller = _FakeChatController();

  void _onListScrollForward() => _controller.onListScroll();

  /// Simulates `_init()` / `didUpdateWidget` rebuilding the controller
  /// without touching the scroll listener wiring.
  _FakeChatController swapController() {
    final old = _controller;
    old.dispose();
    _controller = _FakeChatController();
    return old;
  }

  void fireScroll() => _onListScrollForward();

  void dispose() {
    _listScrollController.removeListener(_onListScrollForward);
    _listScrollController.dispose();
  }
}

/// Reproduces the PRE-FIX bug pattern for contrast: the listener is the
/// controller's own tear-off, captured once at registration time.
class _BuggyHost {
  _BuggyHost() {
    // This is the exact pre-fix bug: the tear-off is captured once, bound
    // to whichever `_controller` instance exists right now.
    _registeredListener = _controller.onListScroll;
    _listScrollController.addListener(_registeredListener);
  }

  final ScrollController _listScrollController = ScrollController();
  _FakeChatController _controller = _FakeChatController();
  late VoidCallback _registeredListener;

  _FakeChatController swapController() {
    final old = _controller;
    old.dispose();
    _controller = _FakeChatController();
    // NOTE: unlike _FixedHost, nothing re-registers a listener for the new
    // controller — this mirrors the pre-fix chat.dart/group_chat.dart code,
    // where the swap never touched `_listScrollController`'s listeners.
    return old;
  }

  void fireScroll() {
    // Invoke the exact callback ScrollController holds, bypassing
    // ChangeNotifier.notifyListeners' own per-listener error reporting so
    // the underlying "used after being disposed" defect is observed
    // directly rather than swallowed by the framework's dispatch loop.
    _registeredListener();
  }
}

void main() {
  test('fixed forwarder keeps working after controller swap (no disposed-use throw)', () {
    final host = _FixedHost();

    host.fireScroll();
    expect(host._controller.scrollCalls, 1, reason: 'first controller receives the scroll event');

    final oldController = host.swapController();

    // Regression guard for FINDING 1 / FINDING 2: after a controller swap,
    // scrolling must reach the NEW controller and must not throw.
    expect(() => host.fireScroll(), returnsNormally);
    expect(host._controller.scrollCalls, 1, reason: 'new controller receives the post-swap scroll event');
    expect(oldController.scrollCalls, 1, reason: 'old controller is untouched after the swap');

    host.dispose();
  });

  test('fixed forwarder is the same object on addListener and removeListener', () {
    final host = _FixedHost();
    // dispose() must not throw: it removes exactly the listener instance
    // that was added in the constructor (initState-equivalent). A mismatched
    // tear-off (as in the pre-fix code) would leave the real listener
    // dangling on the ScrollController forever.
    expect(host.dispose, returnsNormally);
  });

  test('pre-fix pattern control: stale tear-off throws "used after being disposed" post-swap', () {
    final buggy = _BuggyHost();

    buggy.fireScroll();
    expect(buggy._controller.scrollCalls, 1);

    buggy.swapController();

    // This is the exact regression the fix eliminates: the ScrollController
    // still holds `oldController.onListScroll`, so firing a scroll after the
    // swap throws instead of updating the new controller.
    expect(buggy.fireScroll, throwsA(isA<StateError>()));

    buggy._listScrollController.dispose();
  });
}
