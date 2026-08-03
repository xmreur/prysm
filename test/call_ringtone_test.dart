import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/call/call_ringtone.dart';

void main() {
  tearDown(CallRingtone.resetState);

  group('CallRingtone fake', () {
    test('start is idempotent while already playing', () async {
      final ringtone = _RecordingCallRingtone();
      CallRingtone.testOverride = ringtone;

      await ringtone.start();
      await ringtone.start();

      expect(ringtone.startCount, 2);
      expect(ringtone.isPlaying, isTrue);
    });

    test('stop is idempotent when not playing', () async {
      final ringtone = _RecordingCallRingtone();
      CallRingtone.testOverride = ringtone;

      await ringtone.stop();
      await ringtone.stop();

      expect(ringtone.stopCount, 2);
      expect(ringtone.isPlaying, isFalse);
    });
  });

  group('CallRingtone.syncForState', () {
    test('starts ringtone on incoming call', () async {
      final ringtone = _RecordingCallRingtone();
      CallRingtone.testOverride = ringtone;

      await CallRingtone.syncForState(
        const CallSnapshot(
          state: CallState.incoming,
          peerOnion: 'peer.onion',
          callId: 'call-1',
        ),
        const CallSnapshot(state: CallState.idle),
      );

      expect(ringtone.startCount, 1);
      expect(ringtone.isPlaying, isTrue);
    });

    test('stops ringtone when accepting incoming call', () async {
      final ringtone = _RecordingCallRingtone();
      CallRingtone.testOverride = ringtone;

      const incoming = CallSnapshot(
        state: CallState.incoming,
        peerOnion: 'peer.onion',
        callId: 'call-1',
      );
      const connecting = CallSnapshot(
        state: CallState.connecting,
        peerOnion: 'peer.onion',
        callId: 'call-1',
      );

      await CallRingtone.syncForState(incoming, const CallSnapshot(state: CallState.idle));
      await CallRingtone.syncForState(connecting, incoming);

      expect(ringtone.startCount, 1);
      expect(ringtone.stopCount, 1);
      expect(ringtone.isPlaying, isFalse);
    });

    test('stops ringtone when leaving incoming state', () async {
      final ringtone = _RecordingCallRingtone();
      CallRingtone.testOverride = ringtone;

      const incoming = CallSnapshot(
        state: CallState.incoming,
        peerOnion: 'peer.onion',
        callId: 'call-1',
      );

      await CallRingtone.syncForState(incoming, const CallSnapshot(state: CallState.idle));
      await CallRingtone.syncForState(
        const CallSnapshot(state: CallState.idle),
        incoming,
      );

      expect(ringtone.startCount, 1);
      expect(ringtone.stopCount, 1);
      expect(ringtone.isPlaying, isFalse);
    });
  });
}

class _RecordingCallRingtone implements CallRingtonePort {
  int startCount = 0;
  int stopCount = 0;
  bool _playing = false;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> start() async {
    startCount++;
    _playing = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _playing = false;
  }
}
