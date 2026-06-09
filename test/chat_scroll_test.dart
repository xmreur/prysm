import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/chat_scroll.dart';

void main() {
  test('isChatScrolledToBottom returns true without clients', () {
    final controller = ScrollController();
    expect(isChatScrolledToBottom(controller), isTrue);
    controller.dispose();
  });
}
