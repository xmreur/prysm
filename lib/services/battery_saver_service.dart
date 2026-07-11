import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/battery_level_reading.dart';
import 'package:prysm/util/logging.dart';

/// Tracks manual battery saving, OS low-power mode, and auto-enable at low charge.
class BatterySaverService {
  BatterySaverService._();
  static final BatterySaverService instance = BatterySaverService._();

  static const int autoEnableThresholdPercent = 10;
  static const int autoDisableThresholdPercent = 15;

  final Battery _battery = Battery();
  final _changedController = StreamController<void>.broadcast();

  Stream<void> get onChanged => _changedController.stream;

  Timer? _levelPollTimer;
  StreamSubscription<BatteryState>? _stateSub;
  bool _initialized = false;

  int? _batteryLevel;
  BatteryState? _batteryState;
  bool _isCharging = false;
  bool _lowBatteryAuto = false;
  bool _osBatterySaveMode = false;
  bool _userDismissedAuto = false;
  bool _lastActive = false;

  bool get isActive =>
      SettingsService().enableBatterySaving ||
      _lowBatteryAuto ||
      _osBatterySaveMode;

  bool get isAutoLowBattery => _lowBatteryAuto;

  bool get isOsBatterySaveMode => _osBatterySaveMode;

  int? get batteryLevel => _batteryLevel;

  String get statusSubtitle {
    if (_lowBatteryAuto && _batteryLevel != null) {
      return 'Auto-enabled — battery at $_batteryLevel%';
    }
    if (_osBatterySaveMode) {
      return 'Auto-enabled — device power saver on';
    }
    if (SettingsService().enableBatterySaving) {
      return 'Reduces polling and background activity';
    }
    return 'Auto-enables at $autoEnableThresholdPercent% battery or below';
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _stateSub = _battery.onBatteryStateChanged.listen((_) {
      unawaited(_refresh());
    });

    _levelPollTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => unawaited(_refresh()),
    );

    await _refresh();
  }

  Future<void> dispose() async {
    _levelPollTimer?.cancel();
    await _stateSub?.cancel();
    await _changedController.close();
    _initialized = false;
  }

  Future<void> setUserEnabled(bool enabled) async {
    if (enabled) {
      _userDismissedAuto = false;
      await SettingsService().setEnableBatterySaving(true);
    } else {
      await SettingsService().setEnableBatterySaving(false);
      if (_lowBatteryAuto) {
        _userDismissedAuto = true;
      }
    }
    _notifyIfChanged();
  }

  Future<void> _refresh() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
    } catch (e) {
      Logging.error('Battery level unavailable: $e', 'BatterySaverService');
      _batteryLevel = null;
    }

    try {
      final state = await _battery.batteryState;
      _batteryState = state;
      _isCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (e) {
      Logging.error('Battery state unavailable: $e', 'BatterySaverService');
      _batteryState = null;
      _isCharging = false;
    }

    try {
      _osBatterySaveMode = await _battery.isInBatterySaveMode;
    } catch (_) {
      _osBatterySaveMode = false;
    }

    final level = _batteryLevel;
    if ((level != null && level > autoDisableThresholdPercent) || _isCharging) {
      _userDismissedAuto = false;
    }

    _lowBatteryAuto = BatteryLevelReading.shouldAutoEnable(
      level: level,
      state: _batteryState,
      isCharging: _isCharging,
      userDismissedAuto: _userDismissedAuto,
      threshold: autoEnableThresholdPercent,
    );

    _notifyIfChanged();
  }

  void _notifyIfChanged() {
    final active = isActive;
    if (active == _lastActive) return;
    _lastActive = active;
    _changedController.add(null);
  }
}
