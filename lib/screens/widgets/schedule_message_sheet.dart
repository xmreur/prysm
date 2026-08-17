import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/util/schedule_time_format.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

/// How far ahead a message can be scheduled.
const scheduleHorizonDays = 60;

/// Asks the user when a message should be sent, returning null if dismissed.
///
/// Material's showDatePicker/showTimePicker cannot be used: the app root is a
/// WidgetsApp, so there is no MaterialLocalizations ancestor.
Future<DateTime?> showScheduleMessageSheet({
  required BuildContext context,
  DateTime? initial,
}) {
  return showPrysmSheet<DateTime>(
    context: context,
    builder: (ctx) => _ScheduleSheet(initial: initial),
  );
}

class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet({this.initial});

  final DateTime? initial;

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  static const _itemExtent = 40.0;
  static const _wheelHeight = 200.0;

  late final DateTime _firstDay;
  late final List<DateTime> _days;

  late final FixedExtentScrollController _dayController;
  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;
  late final FixedExtentScrollController _periodController;

  late int _dayIndex;
  late int _hourIndex;
  late int _minuteIndex;
  late int _periodIndex;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _firstDay = DateTime(now.year, now.month, now.day);
    _days = List.generate(
      scheduleHorizonDays,
      (i) => _firstDay.add(Duration(days: i)),
    );

    final start = _clampToRange(widget.initial ?? _defaultStart(now));
    _dayIndex = DateTime(start.year, start.month, start.day)
        .difference(_firstDay)
        .inDays;
    _hourIndex = (start.hour % 12 == 0 ? 12 : start.hour % 12) - 1;
    _minuteIndex = start.minute;
    _periodIndex = start.hour >= 12 ? 1 : 0;

    _dayController = FixedExtentScrollController(initialItem: _dayIndex);
    _hourController = FixedExtentScrollController(initialItem: _hourIndex);
    _minuteController = FixedExtentScrollController(initialItem: _minuteIndex);
    _periodController = FixedExtentScrollController(initialItem: _periodIndex);
  }

  @override
  void dispose() {
    _dayController.dispose();
    _hourController.dispose();
    _minuteController.dispose();
    _periodController.dispose();
    super.dispose();
  }

  /// Next round half-hour an hour out, so the sheet opens on a sane value.
  static DateTime _defaultStart(DateTime now) {
    final rounded = now.add(const Duration(hours: 1));
    return DateTime(
      rounded.year,
      rounded.month,
      rounded.day,
      rounded.hour + (rounded.minute < 30 ? 0 : 1),
      rounded.minute < 30 ? 30 : 0,
    );
  }

  DateTime _clampToRange(DateTime value) {
    final last = _days.last;
    if (value.isBefore(_firstDay)) return _defaultStart(DateTime.now());
    if (value.isAfter(DateTime(last.year, last.month, last.day, 23, 59))) {
      return DateTime(last.year, last.month, last.day, value.hour, value.minute);
    }
    return value;
  }

  DateTime get _selected {
    final day = _days[_dayIndex];
    final hour12 = _hourIndex + 1;
    final hour24 = _periodIndex == 1 ? (hour12 % 12) + 12 : hour12 % 12;
    return DateTime(day.year, day.month, day.day, hour24, _minuteIndex);
  }

  bool get _isValid => _selected.isAfter(DateTime.now());

  String _dayLabel(DateTime day) {
    final daysAway = day.difference(_firstDay).inDays;
    if (daysAway == 0) return 'Today';
    if (daysAway == 1) return context.l10n.tomorrow;
    return '${formatScheduleWeekday(day)} ${formatScheduleDate(day)}';
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PrysmTokens.spacing20,
            PrysmTokens.spacing8,
            PrysmTokens.spacing20,
            PrysmTokens.spacing4,
          ),
          child: Text('Schedule message', style: style.titleStyle),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PrysmTokens.spacing20,
            0,
            PrysmTokens.spacing20,
            PrysmTokens.spacing12,
          ),
          child: Text(
            _isValid
                ? 'Sends ${formatScheduleLabel(_selected)}'
                : 'Choose a time in the future',
            style: style.captionStyle.copyWith(
              color: _isValid ? tokens.textSecondary : tokens.danger,
            ),
          ),
        ),
        const PrysmDivider(),
        SizedBox(
          height: _wheelHeight,
          child: Stack(
            children: [
              Center(
                child: Container(
                  height: _itemExtent,
                  margin: const EdgeInsets.symmetric(
                    horizontal: PrysmTokens.spacing12,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.surfaceElevated,
                    borderRadius:
                        BorderRadius.circular(PrysmTokens.radiusChip),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: _Wheel(
                      controller: _dayController,
                      itemExtent: _itemExtent,
                      count: _days.length,
                      selectedIndex: _dayIndex,
                      onSelected: (i) => setState(() => _dayIndex = i),
                      labelAt: (i) => _dayLabel(_days[i]),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _Wheel(
                      controller: _hourController,
                      itemExtent: _itemExtent,
                      count: 12,
                      selectedIndex: _hourIndex,
                      onSelected: (i) => setState(() => _hourIndex = i),
                      labelAt: (i) => '${i + 1}',
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _Wheel(
                      controller: _minuteController,
                      itemExtent: _itemExtent,
                      count: 60,
                      selectedIndex: _minuteIndex,
                      onSelected: (i) => setState(() => _minuteIndex = i),
                      labelAt: (i) => i.toString().padLeft(2, '0'),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: _Wheel(
                      controller: _periodController,
                      itemExtent: _itemExtent,
                      count: 2,
                      selectedIndex: _periodIndex,
                      onSelected: (i) => setState(() => _periodIndex = i),
                      labelAt: (i) => i == 0 ? 'AM' : 'PM',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const PrysmDivider(),
        Padding(
          padding: const EdgeInsets.all(PrysmTokens.spacing16),
          child: Row(
            children: [
              Expanded(
                child: PrysmButton(
                  label: context.l10n.cancel,
                  variant: PrysmButtonVariant.secondary,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: PrysmTokens.spacing12),
              Expanded(
                child: PrysmButton(
                  label: context.l10n.schedule,
                  onPressed:
                      _isValid ? () => Navigator.pop(context, _selected) : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Wheel extends StatelessWidget {
  const _Wheel({
    required this.controller,
    required this.itemExtent,
    required this.count,
    required this.selectedIndex,
    required this.onSelected,
    required this.labelAt,
  });

  final FixedExtentScrollController controller;
  final double itemExtent;
  final int count;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String Function(int index) labelAt;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: itemExtent,
      physics: const FixedExtentScrollPhysics(),
      perspective: 0.002,
      diameterRatio: 1.6,
      onSelectedItemChanged: onSelected,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: count,
        builder: (ctx, index) {
          final isSelected = index == selectedIndex;
          return Center(
            child: Text(
              labelAt(index),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.bodyStyle.copyWith(
                color: isSelected
                    ? style.tokens.textPrimary
                    : style.tokens.textMuted,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          );
        },
      ),
    );
  }
}
