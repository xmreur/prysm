import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/locale_override.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/schedule_time_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime(2026, 8, 3, 10, 0); // Monday

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    resetScheduleDateFormattingForTests();
    final service = SettingsService();
    await service.init();
    await service.setLocaleOverride(LocaleOverride.en);
    await ensureScheduleDateFormatting();
  });

  test('midnight and noon use 12-hour clock, not 0', () {
    expect(formatScheduleClock(DateTime(2026, 8, 3, 0, 5)), '12:05 AM');
    expect(formatScheduleClock(DateTime(2026, 8, 3, 12, 0)), '12:00 PM');
    expect(formatScheduleClock(DateTime(2026, 8, 3, 13, 7)), '1:07 PM');
  });

  test('today and tomorrow are named', () {
    expect(
      formatScheduleLabel(DateTime(2026, 8, 3, 16, 30), now: now),
      'Today at 4:30 PM',
    );
    expect(
      formatScheduleLabel(DateTime(2026, 8, 4, 9, 0), now: now),
      'Tomorrow at 9:00 AM',
    );
  });

  test('within the week uses the weekday, beyond it adds the date', () {
    expect(
      formatScheduleLabel(DateTime(2026, 8, 6, 9, 0), now: now),
      'Thu at 9:00 AM',
    );
    expect(
      formatScheduleLabel(DateTime(2026, 8, 13, 9, 0), now: now),
      'Thu, Aug 13 at 9:00 AM',
    );
  });

  test('a later time on the same day still counts as today', () {
    expect(
      formatScheduleLabel(DateTime(2026, 8, 3, 23, 59), now: now),
      'Today at 11:59 PM',
    );
  });
}
