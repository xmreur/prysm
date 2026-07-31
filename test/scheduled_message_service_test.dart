import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/scheduled_messages_db.dart';
import 'package:prysm/models/scheduled_message.dart';
import 'package:prysm/services/scheduled_message_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/scheduled_activity_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late KeyManager keyManager;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => ScheduledMessagesDb.createTable(db),
      ),
    );
    ScheduledMessagesDb.setDatabaseForTest(db);
    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
  });

  tearDown(() => ScheduledMessagesDb.setDatabaseForTest(null));

  ScheduledMessageService serviceWith({
    List<ScheduledMessage>? directSent,
    List<ScheduledMessage>? groupSent,
    bool succeed = true,
  }) {
    return ScheduledMessageService(
      userId: 'me.onion',
      keyManager: keyManager,
      directSender: (m) async {
        directSent?.add(m);
        return succeed;
      },
      groupSender: (m) async {
        groupSent?.add(m);
        return succeed;
      },
    );
  }

  test('schedule stores the body encrypted, never as plaintext', () async {
    final service = serviceWith();
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'secret plan',
      sendAt: DateTime.now().add(const Duration(hours: 1)),
    );

    final rows = await ScheduledMessagesDb.getForConversation('peer.onion');
    expect(rows.length, 1);
    expect(rows.first['body'], isNot(contains('secret plan')));

    final pending = await service.pendingFor('peer.onion');
    expect(pending.single.body, 'secret plan');
  });

  test('flushDue only sends messages whose time has arrived', () async {
    final service = serviceWith();
    final now = DateTime.now();
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'due',
      sendAt: now.subtract(const Duration(minutes: 5)),
    );
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'later',
      sendAt: now.add(const Duration(hours: 2)),
    );

    final sent = <ScheduledMessage>[];
    expect(await serviceWith(directSent: sent).flushDue(now: now), isTrue);

    expect(sent.map((m) => m.body).toList(), ['due']);
    final remaining = await service.pendingFor('peer.onion');
    expect(remaining.single.body, 'later');
  });

  test('a message overdue from a previous run is still sent, not dropped',
      () async {
    final service = serviceWith();
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'missed while app was closed',
      sendAt: DateTime.now().subtract(const Duration(days: 3)),
    );

    final sent = <ScheduledMessage>[];
    await serviceWith(directSent: sent).flushDue();

    expect(sent.single.body, 'missed while app was closed');
    expect(await service.pendingCountFor('peer.onion'), 0);
  });

  test('a failed send stays queued for the next flush', () async {
    final service = serviceWith();
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'retry me',
      sendAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );

    expect(await serviceWith(succeed: false).flushDue(), isFalse);
    expect(await service.pendingCountFor('peer.onion'), 1);

    final sent = <ScheduledMessage>[];
    expect(await serviceWith(directSent: sent).flushDue(), isTrue);
    expect(sent.single.body, 'retry me');
    expect(await service.pendingCountFor('peer.onion'), 0);
  });

  test('group messages route to the group sender', () async {
    final service = serviceWith();
    await service.schedule(
      conversationId: 'group-1',
      isGroup: true,
      text: 'hi team',
      sendAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );

    final direct = <ScheduledMessage>[];
    final group = <ScheduledMessage>[];
    await serviceWith(directSent: direct, groupSent: group).flushDue();

    expect(direct, isEmpty);
    expect(group.single.body, 'hi team');
    expect(group.single.isGroup, isTrue);
  });

  test('cancel removes a pending message without sending it', () async {
    final service = serviceWith();
    final scheduled = await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'never mind',
      sendAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );

    await service.cancel(scheduled.id);

    final sent = <ScheduledMessage>[];
    expect(await serviceWith(directSent: sent).flushDue(), isFalse);
    expect(sent, isEmpty);
  });

  test('pending list is ordered by send time and scoped per conversation',
      () async {
    final service = serviceWith();
    final now = DateTime.now();
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'second',
      sendAt: now.add(const Duration(hours: 2)),
    );
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'first',
      sendAt: now.add(const Duration(hours: 1)),
    );
    await service.schedule(
      conversationId: 'other.onion',
      isGroup: false,
      text: 'elsewhere',
      sendAt: now.add(const Duration(hours: 1)),
    );

    final pending = await service.pendingFor('peer.onion');
    expect(pending.map((m) => m.body).toList(), ['first', 'second']);
    expect(await service.pendingCountFor('other.onion'), 1);
  });

  test('nextDueAt reports the earliest queued time, or null when empty',
      () async {
    final service = serviceWith();
    expect(await service.nextDueAt(), isNull);

    final now = DateTime.now();
    final soon = now.add(const Duration(minutes: 5));
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'later',
      sendAt: now.add(const Duration(hours: 3)),
    );
    await service.schedule(
      conversationId: 'group-1',
      isGroup: true,
      text: 'sooner',
      sendAt: soon,
    );

    expect(
      await service.nextDueAt(),
      DateTime.fromMillisecondsSinceEpoch(soon.millisecondsSinceEpoch),
    );
  });

  test('nextDueAt skips ahead once the earliest message is sent', () async {
    final service = serviceWith();
    final now = DateTime.now();
    final later = now.add(const Duration(hours: 3));
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'overdue',
      sendAt: now.subtract(const Duration(minutes: 1)),
    );
    await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'later',
      sendAt: later,
    );

    expect(await service.flushDue(), isTrue);
    expect(
      await service.nextDueAt(),
      DateTime.fromMillisecondsSinceEpoch(later.millisecondsSinceEpoch),
    );
  });

  test('scheduling and cancelling both announce the queue changed', () async {
    final service = serviceWith();
    final events = <void>[];
    final sub = ScheduledActivityNotifier.instance.onChanged.listen(events.add);
    addTearDown(sub.cancel);

    final message = await service.schedule(
      conversationId: 'peer.onion',
      isGroup: false,
      text: 'hello',
      sendAt: DateTime.now().add(const Duration(hours: 1)),
    );
    await pumpEventQueue();
    expect(events.length, 1);

    await service.cancel(message.id);
    await pumpEventQueue();
    expect(events.length, 2);
  });
}
