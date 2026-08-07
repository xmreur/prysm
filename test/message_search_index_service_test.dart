import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/message_search_index_service.dart';

void main() {
  test('buildSnippet includes match context', () {
    final snippet = MessageSearchIndexService.buildSnippet(
      'The quick brown fox jumps over the lazy dog',
      'fox',
    );
    expect(snippet.toLowerCase(), contains('fox'));
  });

  test('searchable type helpers', () {
    expect(MessageSearchIndexService.isSearchableDirectType('text'), isTrue);
    expect(MessageSearchIndexService.isSearchableDirectType('reaction'), isFalse);
    expect(MessageSearchIndexService.isSearchableSelfType('audio'), isTrue);
  });
}
