import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/battery_level_reading.dart';

void main() {
  test('desktop no-battery reading is not reliable', () {
    expect(
      BatteryLevelReading.isReliable(0, BatteryState.unknown),
      isFalse,
    );
    expect(
      BatteryLevelReading.shouldAutoEnable(
        level: 0,
        state: BatteryState.unknown,
        isCharging: false,
        userDismissedAuto: false,
      ),
      isFalse,
    );
  });

  test('laptop low battery still auto-enables', () {
    expect(
      BatteryLevelReading.shouldAutoEnable(
        level: 8,
        state: BatteryState.discharging,
        isCharging: false,
        userDismissedAuto: false,
      ),
      isTrue,
    );
    expect(
      BatteryLevelReading.shouldAutoEnable(
        level: 0,
        state: BatteryState.discharging,
        isCharging: false,
        userDismissedAuto: false,
      ),
      isTrue,
    );
  });

  test('charging or dismissed suppresses auto-enable', () {
    expect(
      BatteryLevelReading.shouldAutoEnable(
        level: 5,
        state: BatteryState.discharging,
        isCharging: true,
        userDismissedAuto: false,
      ),
      isFalse,
    );
    expect(
      BatteryLevelReading.shouldAutoEnable(
        level: 5,
        state: BatteryState.discharging,
        isCharging: false,
        userDismissedAuto: true,
      ),
      isFalse,
    );
  });
}
