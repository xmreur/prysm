import 'package:battery_plus/battery_plus.dart';

/// Interprets [battery_plus] readings, including ambiguous desktop values.
class BatteryLevelReading {
  BatteryLevelReading._();

  /// UPower on Linux (and similar APIs elsewhere) often report 0% with
  /// [BatteryState.unknown] when no battery is present.
  static bool isReliable(int? level, BatteryState? state) {
    if (level == null || level < 0 || level > 100) return false;
    if (level == 0) {
      return state != null && state != BatteryState.unknown;
    }
    return true;
  }

  static bool shouldAutoEnable({
    required int? level,
    required BatteryState? state,
    required bool isCharging,
    required bool userDismissedAuto,
    int threshold = 10,
  }) {
    if (!isReliable(level, state) || isCharging || userDismissedAuto) {
      return false;
    }
    return level! <= threshold;
  }
}
