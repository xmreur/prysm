import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:prysm/services/settings_service.dart';

String _dateLocale() {
  switch (SettingsService().resolvedLocale.languageCode) {
    case 'it':
      return 'it_IT';
    default:
      return 'en_US';
  }
}

String? _loadedDateLocale;
bool _dateSymbolsReady = false;

Future<void> ensureScheduleDateFormatting() async {
  final locale = _dateLocale();
  if (_dateSymbolsReady && _loadedDateLocale == locale) return;
  await initializeDateFormatting(locale, null);
  _loadedDateLocale = locale;
  _dateSymbolsReady = true;
}

void resetScheduleDateFormattingForTests() {
  _dateSymbolsReady = false;
  _loadedDateLocale = null;
}

String formatScheduleClock(DateTime dt) {
  return DateFormat.jm(_dateLocale())
      .format(dt)
      .replaceAll('\u202f', ' ');
}

String formatScheduleDate(DateTime dt) {
  return DateFormat.MMMd(_dateLocale()).format(dt);
}

String formatScheduleWeekday(DateTime dt) {
  return DateFormat.E(_dateLocale()).format(dt);
}

String formatLocalizedShortDateTime(DateTime dt) {
  return DateFormat.Md(_dateLocale()).add_Hm().format(dt);
}

int _calendarDayDelta(DateTime from, DateTime to) {
  final fromDay = DateTime.utc(from.year, from.month, from.day);
  final toDay = DateTime.utc(to.year, to.month, to.day);
  return toDay.difference(fromDay).inDays;
}

/// "Today at 4:30 PM" / "Tomorrow at 9:00 AM" / "Thu, Aug 6 at 9:00 AM".
String formatScheduleLabel(DateTime sendAt, {DateTime? now}) {
  final l10n = SettingsService().localizations;
  final reference = now ?? DateTime.now();
  final daysAway = _calendarDayDelta(reference, sendAt);
  final time = formatScheduleClock(sendAt);

  if (daysAway == 0) return l10n.scheduleTodayAt(time);
  if (daysAway == 1) return l10n.scheduleTomorrowAt(time);
  if (daysAway > 1 && daysAway < 7) {
    return l10n.scheduleWeekdayAt(formatScheduleWeekday(sendAt), time);
  }
  final dateLabel = DateFormat('EEE, MMM d', _dateLocale()).format(sendAt);
  return l10n.scheduleDateAt(dateLabel, time);
}
