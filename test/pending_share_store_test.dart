import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/services/pending_share_store.dart';

void main() {
  test('PendingShareStore set peek take clear', () {
    final store = PendingShareStore.instance;
    store.clear();

    expect(store.peek(), isNull);

    const content = SharedContent(kind: SharedContentKind.text, text: 'hello');
    store.set(content);
    expect(store.peek(), same(content));

    final taken = store.take();
    expect(taken, same(content));
    expect(store.peek(), isNull);

    store.set(content);
    store.clear();
    expect(store.peek(), isNull);
  });
}
