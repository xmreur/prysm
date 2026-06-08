import 'package:prysm/services/battery_saver_service.dart';

/// Central intervals used when [BatterySaverService.isActive] is true.
class BatterySaverPolicy {
  BatterySaverPolicy._();

  static bool get active => BatterySaverService.instance.isActive;

  static int chatPollActiveSeconds([bool? saving]) =>
      (saving ?? active) ? 8 : 2;

  static int chatPollIdleSeconds([bool? saving]) =>
      (saving ?? active) ? 15 : 5;

  static Duration syncTickBacklog([bool? saving]) =>
      (saving ?? active)
          ? const Duration(seconds: 30)
          : const Duration(seconds: 10);

  static Duration syncTickIdle([bool? saving]) =>
      (saving ?? active)
          ? const Duration(seconds: 120)
          : const Duration(seconds: 30);

  static Duration homeRefreshInterval([bool? saving]) =>
      (saving ?? active)
          ? const Duration(seconds: 120)
          : const Duration(seconds: 30);

  static Duration torHealthInterval([bool? saving]) =>
      (saving ?? active)
          ? const Duration(seconds: 60)
          : const Duration(seconds: 15);

  static Duration trayPollInterval([bool? saving]) =>
      (saving ?? active)
          ? const Duration(seconds: 60)
          : const Duration(seconds: 15);

  static Duration peerStatusInterval([bool? saving]) =>
      (saving ?? active)
          ? const Duration(seconds: 300)
          : const Duration(seconds: 90);

  static Duration loadUsersDebounce([bool? saving]) =>
      (saving ?? active)
          ? const Duration(milliseconds: 800)
          : const Duration(milliseconds: 400);

  static const int wakeHintMaxPeers = 20;

  static const Duration wakeHintSendCooldown = Duration(minutes: 5);

  static const Duration wakeHintReceiveDebounce = Duration(seconds: 30);

  static const Duration wakeHintMinOfflineBeforeBroadcast = Duration(seconds: 30);

  static Duration wakeHintStaggerMin([bool? saving]) =>
      (saving ?? active)
          ? const Duration(milliseconds: 500)
          : const Duration(milliseconds: 200);

  static Duration wakeHintStaggerMax([bool? saving]) =>
      (saving ?? active)
          ? const Duration(milliseconds: 800)
          : const Duration(milliseconds: 400);
}
