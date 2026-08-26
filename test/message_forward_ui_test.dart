import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/screens/share_target_picker_screen.dart';
import 'package:prysm/screens/widgets/message_forwarded_label.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/util/key_manager.dart';

import 'pump_prysm_l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Forwarded label shows only when metadata is set', (tester) async {
    await pumpWithPrysmL10n(
      tester,
      const MessageForwardedLabel(metadata: {'forwarded': true}),
    );
    expect(find.text('Forwarded'), findsOneWidget);

    await pumpWithPrysmL10n(
      tester,
      const MessageForwardedLabel(),
    );
    expect(find.text('Forwarded'), findsNothing);
  });

  testWidgets('forward picker toggle defaults on', (tester) async {
    await pumpWithPrysmL10n(
      tester,
      ShareTargetPickerScreen(
        content: const SharedContent(
          kind: SharedContentKind.text,
          text: 'hello',
        ),
        conversations: [
          DirectConversation(
            Contact(
              id: 'peer.onion',
              name: 'Peer',
              avatarUrl: '',
              identityJson: '{}',
            ),
          ),
        ],
        userId: 'me.onion',
        userName: 'Me',
        userAvatarBase64: null,
        contacts: const [],
        keyManager: KeyManager(),
        groupById: (_) => null,
        showForwardedToggle: true,
        customSend: (_, {required markForwarded}) async {},
      ),
      width: 400,
    );
    await tester.pump();

    expect(find.text('Show as forwarded'), findsOneWidget);
    expect(tester.widget<PrysmSwitch>(find.byType(PrysmSwitch)).value, isTrue);

    await tester.tap(find.byType(PrysmSwitch));
    await tester.pump();
    expect(tester.widget<PrysmSwitch>(find.byType(PrysmSwitch)).value, isFalse);
  });
}
