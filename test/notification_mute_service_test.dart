import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await NotificationMuteService.instance.init();
  });

  test('user mute expires after duration', () async {
    final service = NotificationMuteService.instance;
    await service.mute(MuteTarget.user, 'alice.onion', MuteDuration.oneHour);
    expect(service.isMuted(MuteTarget.user, 'alice.onion'), isTrue);

    await service.unmute(MuteTarget.user, 'alice.onion');
    expect(service.isMuted(MuteTarget.user, 'alice.onion'), isFalse);
  });

  test('group forever mute persists until removed', () async {
    final service = NotificationMuteService.instance;
    await service.mute(MuteTarget.group, 'group-1', MuteDuration.forever);

    final info = service.muteInfo(MuteTarget.group, 'group-1');
    expect(info, isNotNull);
    expect(info!.isForever, isTrue);
    expect(service.isMuted(MuteTarget.group, 'group-1'), isTrue);

    await service.unmute(MuteTarget.group, 'group-1');
    expect(service.muteInfo(MuteTarget.group, 'group-1'), isNull);
  });

  test('user and group mutes are independent', () async {
    final service = NotificationMuteService.instance;
    await service.mute(MuteTarget.user, 'bob.onion', MuteDuration.twoHours);
    await service.mute(MuteTarget.group, 'group-2', MuteDuration.fourHours);

    expect(service.isMuted(MuteTarget.user, 'bob.onion'), isTrue);
    expect(service.isMuted(MuteTarget.group, 'group-2'), isTrue);
    expect(service.isMuted(MuteTarget.user, 'group-2'), isFalse);
    expect(service.isMuted(MuteTarget.group, 'bob.onion'), isFalse);
  });
}
