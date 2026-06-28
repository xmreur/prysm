import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/transport/ws_dial_policy.dart';

void main() {
  test('smaller onion dials larger onion', () {
    expect(
      shouldDialPeer(
        localOnion: 'aaa.onion',
        peerOnion: 'bbb.onion',
      ),
      isTrue,
    );
  });

  test('larger onion does not dial smaller onion', () {
    expect(
      shouldDialPeer(
        localOnion: 'bbb.onion',
        peerOnion: 'aaa.onion',
      ),
      isFalse,
    );
  });

  test('equal onions do not dial', () {
    expect(
      shouldDialPeer(
        localOnion: 'same.onion',
        peerOnion: 'same.onion',
      ),
      isFalse,
    );
  });
}
