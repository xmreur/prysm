/// Preset durations for per-conversation disappearing messages.
class DisappearingTimerPreset {
  const DisappearingTimerPreset({
    required this.seconds,
    required this.label,
  });

  final int seconds;
  final String label;
}

/// Signal-aligned disappearing-message timer options.
class DisappearingTimerPresets {
  DisappearingTimerPresets._();

  static const List<DisappearingTimerPreset> all = [
    DisappearingTimerPreset(seconds: 30, label: '30 seconds'),
    DisappearingTimerPreset(seconds: 300, label: '5 minutes'),
    DisappearingTimerPreset(seconds: 3600, label: '1 hour'),
    DisappearingTimerPreset(seconds: 28800, label: '8 hours'),
    DisappearingTimerPreset(seconds: 86400, label: '1 day'),
    DisappearingTimerPreset(seconds: 604800, label: '1 week'),
    DisappearingTimerPreset(seconds: 2419200, label: '4 weeks'),
  ];

  static String labelForSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return 'Off';
    for (final preset in all) {
      if (preset.seconds == seconds) return preset.label;
    }
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    if (seconds < 604800) return '${seconds ~/ 86400}d';
    return '${seconds ~/ 604800}w';
  }

  static String shortLabelForSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return '';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    if (seconds < 604800) return '${seconds ~/ 86400}d';
    return '${seconds ~/ 604800}w';
  }
}
