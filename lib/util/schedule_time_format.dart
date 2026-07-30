/// Formatting for scheduled-send times.
///
/// The app has no shared date formatter and no intl dependency, so these
/// mirror the hand-rolled helpers in notification_mute_sheet.dart.
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _weekdays = [
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];

String formatScheduleClock(DateTime dt) {
  final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}

String formatScheduleDate(DateTime dt) =>
    '${_months[dt.month - 1]} ${dt.day}';

String formatScheduleWeekday(DateTime dt) => _weekdays[dt.weekday - 1];

/// "Today at 4:30 PM" / "Tomorrow at 9:00 AM" / "Thu, Aug 6 at 9:00 AM".
String formatScheduleLabel(DateTime sendAt, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final target = DateTime(sendAt.year, sendAt.month, sendAt.day);
  final daysAway = target.difference(today).inDays;
  final time = formatScheduleClock(sendAt);

  if (daysAway == 0) return 'Today at $time';
  if (daysAway == 1) return 'Tomorrow at $time';
  if (daysAway > 1 && daysAway < 7) {
    return '${formatScheduleWeekday(sendAt)} at $time';
  }
  return '${formatScheduleWeekday(sendAt)}, ${formatScheduleDate(sendAt)} at $time';
}
