import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/models/settings.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the default mode holds invites from unknown senders', () {
    expect(Settings().groupInviteMode, GroupInviteMode.holdAsRequest);
  });

  test('the mode survives a JSON round trip', () {
    final restored = Settings.fromJson(
      Settings(groupInviteMode: GroupInviteMode.contactsOnly).toJson(),
    );
    expect(restored.groupInviteMode, GroupInviteMode.contactsOnly);
  });

  test('an unknown stored value falls back to the default', () {
    expect(
      Settings.fromJson({'groupInviteMode': 'whatever-a-future-build-wrote'})
          .groupInviteMode,
      GroupInviteMode.holdAsRequest,
    );
  });

  test('both modes carry a label and an explanatory description', () {
    for (final mode in GroupInviteMode.values) {
      expect(mode.label, isNotEmpty);
      expect(mode.description, isNotEmpty);
      expect(mode.description.length, greaterThan(40));
    }
  });

  test('the setter persists the mode through SettingsService', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SettingsService();
    await service.init();
    addTearDown(
      () => service.setGroupInviteMode(GroupInviteMode.holdAsRequest),
    );

    await service.setGroupInviteMode(GroupInviteMode.contactsOnly);
    expect(service.groupInviteMode, GroupInviteMode.contactsOnly);

    await service.load();
    expect(service.groupInviteMode, GroupInviteMode.contactsOnly);
  });
}
