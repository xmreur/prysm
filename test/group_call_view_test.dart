import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/screens/call/group_call_view.dart';
import 'package:prysm/screens/widgets/call_message_bubble.dart';
import 'package:prysm/screens/widgets/group_call_join_banner.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/services/call/group_call_snapshot.dart';
import 'package:prysm/ui/core/prysm_icons.dart';

import 'pump_prysm_l10n.dart';

void main() {
  testWidgets('the incoming group view offers join and dismiss', (
    tester,
  ) async {
    var joined = 0;
    var dismissed = 0;
    await pumpWithPrysmL10n(
      tester,
      GroupCallJoinBannerHost(
        child: GroupIncomingCallView(
          groupLabel: 'Squad',
          onJoin: () => joined++,
          onDismiss: () => dismissed++,
        ),
      ),
      width: 500,
    );

    expect(find.text('Incoming group call'), findsOneWidget);
    expect(find.text('Squad'), findsWidgets);

    await tester.tap(find.text('Join call'));
    await tester.pump();
    expect(joined, 1);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('the active group view lists participants with mute state', (
    tester,
  ) async {
    await pumpWithPrysmL10n(
      tester,
      const GroupCallJoinBannerHost(
        child: GroupActiveCallView(
          groupLabel: 'Squad',
          snapshot: GroupCallSnapshot(
            state: CallState.active,
            groupId: 'g1',
            callId: 'c1',
          ),
          participants: [
            GroupCallParticipant(
              onion: 'me.onion',
              label: 'Me',
              muted: false,
              isSelf: true,
            ),
            GroupCallParticipant(
              onion: 'alice.onion',
              label: 'Alice',
              muted: true,
              isSelf: false,
            ),
          ],
          onToggleMute: _noop,
          onLeave: _noop,
        ),
      ),
      width: 500,
    );

    expect(find.text('You'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('2 participants'), findsOneWidget);
    // Alice is muted, we are not: one crossed mic per state, plus the mute
    // button which follows localMuted (false here).
    expect(find.byIcon(PrysmIcons.micOff), findsOneWidget);
    expect(find.byIcon(PrysmIcons.mic), findsNWidgets(2));
  });

  testWidgets('a listen-only participant cannot toggle mute', (tester) async {
    var toggles = 0;
    await pumpWithPrysmL10n(
      tester,
      GroupCallJoinBannerHost(
        child: GroupActiveCallView(
          groupLabel: 'Squad',
          snapshot: const GroupCallSnapshot(
            state: CallState.active,
            groupId: 'g1',
            callId: 'c1',
            localMuted: true,
            listenOnly: true,
          ),
          participants: const [],
          onToggleMute: () => toggles++,
          onLeave: _noop,
        ),
      ),
      width: 500,
    );

    expect(find.text('You are muted in this group — listen only'),
        findsOneWidget);
    await tester.tap(find.byIcon(PrysmIcons.micOff));
    await tester.pump();
    expect(toggles, 0);
  });

  testWidgets('the shared call row renders a group call summary', (
    tester,
  ) async {
    await pumpWithPrysmL10n(
      tester,
      CallMessageBubble(
        message: PrysmCallMessage(
          id: 'm1',
          authorId: 'me.onion',
          createdAt: DateTime(2026, 1, 1, 9, 5),
          durationMs: 65000,
          callStatus: 'completed',
          direction: 'outbound',
        ),
      ),
      width: 500,
    );

    expect(find.textContaining('1m 05s'), findsOneWidget);
    expect(find.text('09:05'), findsOneWidget);
  });

  testWidgets('the join banner offers to join a running call', (tester) async {
    var joined = 0;
    await pumpWithPrysmL10n(
      tester,
      GroupCallJoinBannerHost(
        child: GroupCallJoinBanner(onJoin: () => joined++),
      ),
      width: 500,
    );

    expect(find.text('Call in progress'), findsOneWidget);
    await tester.tap(find.text('Join call'));
    await tester.pump();
    expect(joined, 1);
  });
}

void _noop() {}

/// Gives the views a bounded, scrollable box the way the overlay and chat body
/// do, so an unbounded-height Column does not overflow the test surface.
class GroupCallJoinBannerHost extends StatelessWidget {
  const GroupCallJoinBannerHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 700, child: child);
}
