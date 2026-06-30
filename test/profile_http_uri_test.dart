import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/profile_http_uri.dart';

void main() {
  test('build includes requester query parameter when provided', () {
    final uri = ProfileHttpUri.build(
      'peer.onion',
      requesterOnion: 'me.onion',
    );

    expect(uri.toString(), contains('peer.onion'));
    expect(uri.path, '/profile');
    expect(uri.queryParameters['requester'], 'me.onion');
  });

  test('build omits query when requester is absent', () {
    final uri = ProfileHttpUri.build('peer.onion');

    expect(uri.path, '/profile');
    expect(uri.queryParameters, isEmpty);
  });
}
