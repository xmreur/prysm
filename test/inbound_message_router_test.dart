import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/server/inbound_message_router.dart';

void main() {
  test('InboundHandleResult helpers set status codes', () {
    final ok = InboundHandleResult.ok({'status': 'received'});
    expect(ok.statusCode, 200);
    expect(ok.jsonBody?['status'], 'received');

    final bad = InboundHandleResult.badRequest('invalid');
    expect(bad.statusCode, 400);
    expect(bad.jsonBody?['error'], 'invalid');

    final forbidden = InboundHandleResult.forbidden('nope');
    expect(forbidden.statusCode, 403);
  });
}
