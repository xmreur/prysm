import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/screens/call_history_screen.dart';
import 'package:prysm/screens/call_log_detail_screen.dart';
import 'package:prysm/services/call/call_manager.dart';
import 'package:prysm/util/tor_lifecycle_state.dart';
import 'package:prysm/util/tor_runtime_gate.dart';

import 'pump_prysm_l10n.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final now = DateTime.now().millisecondsSinceEpoch;

  final missedInbound = CallLog(
    callId: 'missed-1',
    peerOnion: 'alice.onion',
    direction: CallLogDirection.inbound,
    status: CallLogStatus.missed,
    startedAt: now,
    endedAt: now,
    durationMs: 0,
  );
  final completedOutbound = CallLog(
    callId: 'completed-1',
    peerOnion: 'bob.onion',
    direction: CallLogDirection.outbound,
    status: CallLogStatus.completed,
    startedAt: now - 60000,
    endedAt: now,
    durationMs: 65000,
  );
  final failedOutbound = CallLog(
    callId: 'failed-1',
    peerOnion: 'carol.onion',
    direction: CallLogDirection.outbound,
    status: CallLogStatus.failed,
    startedAt: now - 120000,
    endedAt: now - 120000,
    durationMs: 0,
  );

  final logs = [missedInbound, completedOutbound, failedOutbound];
  final users = <String, Map<String, dynamic>?>{
    'alice.onion': {'name': 'Alice'},
    'bob.onion': {'name': 'Bob'},
    'carol.onion': {'name': 'Carol'},
  };

  CallHistoryScreen history() {
    return CallHistoryScreen(
      onClose: () {},
      debugLogs: logs,
      debugUsers: users,
    );
  }

  setUp(CallManager.resetForTest);
  tearDown(() {
    CallManager.resetForTest();
    TorRuntimeGate.resetForTest(lifecycle: TorLifecycleState.stopped);
  });

  testWidgets('the list shows duration on a completed call', (tester) async {
    await pumpWithPrysmL10n(tester, history());

    expect(find.textContaining('1m 05s'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('tapping a missed inbound log shows Call back and no duration', (
    tester,
  ) async {
    await pumpWithPrysmL10n(tester, history());

    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();

    expect(find.byType(CallLogDetailScreen), findsOneWidget);
    expect(find.text(l10n.callBack), findsOneWidget);
    expect(find.text(l10n.callDuration), findsNothing);
    expect(find.text(l10n.retryCall), findsNothing);
  });

  testWidgets(
    'tapping a completed log shows duration and no place-call button',
    (tester) async {
      await pumpWithPrysmL10n(tester, history());

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();

      expect(find.byType(CallLogDetailScreen), findsOneWidget);
      expect(find.text(l10n.callDuration), findsOneWidget);
      expect(find.text('1m 05s'), findsOneWidget);
      expect(find.text(l10n.callBack), findsNothing);
      expect(find.text(l10n.retryCall), findsNothing);
    },
  );

  testWidgets('tapping a failed outbound log shows Retry call', (tester) async {
    await pumpWithPrysmL10n(tester, history());

    await tester.tap(find.text('Carol'));
    await tester.pumpAndSettle();

    expect(find.text(l10n.retryCall), findsOneWidget);
    expect(find.text(l10n.callBack), findsNothing);
    expect(find.text(l10n.callDuration), findsNothing);
  });

  testWidgets(
    'Call back with an unconfigured CallManager toasts and does not crash',
    (tester) async {
      TorRuntimeGate.resetForTest();

      await pumpWithPrysmL10n(
        tester,
        CallLogDetailScreen(
          log: missedInbound,
          displayName: 'Alice',
          onClose: () {},
        ),
      );

      await tester.tap(find.text(l10n.callBack));
      await tester.pump();

      expect(
        find.text(
          l10n.couldNotStartCallE(
            'Bad state: CallManager.start() must be called first',
          ),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
