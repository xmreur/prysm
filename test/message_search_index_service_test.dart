import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/services/message_search_index_service.dart';

void main() {
  test('buildSnippet includes match context', () {
    final snippet = MessageSearchIndexService.buildSnippet(
      'The quick brown fox jumps over the lazy dog',
      'fox',
    );
    expect(snippet.toLowerCase(), contains('fox'));
  });

  test('buildSnippet returns whole short body for empty query', () {
    expect(
      MessageSearchIndexService.buildSnippet('short body', '   '),
      'short body',
    );
  });

  test('buildSnippet truncates long body without match with trailing ellipsis',
      () {
    final long = List.filled(20, 'abcdefghij').join();
    expect(
      MessageSearchIndexService.buildSnippet(long, 'zzz'),
      '${long.substring(0, 80)}…',
    );
  });

  test('buildSnippet truncates long body with empty query', () {
    final long = List.filled(20, 'abcdefghij').join();
    expect(
      MessageSearchIndexService.buildSnippet(long, ''),
      '${long.substring(0, 80)}…',
    );
  });

  test('buildSnippet shows leading ellipsis for match near the end', () {
    final body = '${'x' * 100}needle';
    expect(
      MessageSearchIndexService.buildSnippet(body, 'needle'),
      '…${body.substring(76)}',
    );
  });

  test('buildSnippet centers on the earliest matching token', () {
    final body = '${'x' * 30}alpha${'y' * 30}beta${'z' * 30}';
    expect(
      MessageSearchIndexService.buildSnippet(body, 'beta alpha'),
      '…${'x' * 24}alpha${'y' * 24}…',
    );
  });

  test('searchable type helpers', () {
    expect(MessageSearchIndexService.isSearchableDirectType('text'), isTrue);
    expect(MessageSearchIndexService.isSearchableDirectType('reaction'), isFalse);
    expect(MessageSearchIndexService.isSearchableSelfType('audio'), isTrue);
    expect(MessageSearchIndexService.isSearchableGroupType(groupTextType), isTrue);
    expect(MessageSearchIndexService.isSearchableGroupType(groupImageType), isTrue);
    expect(MessageSearchIndexService.isSearchableGroupType('text'), isFalse);
    expect(MessageSearchIndexService.isSearchableGroupType('reaction'), isFalse);
  });
}
