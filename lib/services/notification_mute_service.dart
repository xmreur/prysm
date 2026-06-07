import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum MuteTarget { user, group }

enum MuteDuration {
  oneHour,
  twoHours,
  fourHours,
  eightHours,
  forever,
}

extension MuteDurationX on MuteDuration {
  Duration? get duration {
    switch (this) {
      case MuteDuration.oneHour:
        return const Duration(hours: 1);
      case MuteDuration.twoHours:
        return const Duration(hours: 2);
      case MuteDuration.fourHours:
        return const Duration(hours: 4);
      case MuteDuration.eightHours:
        return const Duration(hours: 8);
      case MuteDuration.forever:
        return null;
    }
  }

  String get label {
    switch (this) {
      case MuteDuration.oneHour:
        return '1 hour';
      case MuteDuration.twoHours:
        return '2 hours';
      case MuteDuration.fourHours:
        return '4 hours';
      case MuteDuration.eightHours:
        return '8 hours';
      case MuteDuration.forever:
        return 'Until I turn it back on';
    }
  }
}

class MuteInfo {
  final bool isForever;
  final DateTime? expiresAt;

  const MuteInfo({required this.isForever, this.expiresAt});
}

class NotificationMuteService {
  NotificationMuteService._();
  static final NotificationMuteService instance = NotificationMuteService._();

  static const _storageKey = 'notification_mutes';
  static const int _forever = -1;

  SharedPreferences? _prefs;
  final Map<String, int> _mutes = {};

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _load();
    _pruneExpired();
  }

  Future<void> mute(MuteTarget target, String id, MuteDuration duration) async {
    final key = _keyFor(target, id);
    final expiry = duration == MuteDuration.forever
        ? _forever
        : DateTime.now().add(duration.duration!).millisecondsSinceEpoch;
    _mutes[key] = expiry;
    await _save();
  }

  Future<void> unmute(MuteTarget target, String id) async {
    _mutes.remove(_keyFor(target, id));
    await _save();
  }

  bool isMuted(MuteTarget target, String id) {
    _pruneExpired();
    final expiry = _mutes[_keyFor(target, id)];
    if (expiry == null) return false;
    if (expiry == _forever) return true;
    return DateTime.now().millisecondsSinceEpoch < expiry;
  }

  MuteInfo? muteInfo(MuteTarget target, String id) {
    _pruneExpired();
    final expiry = _mutes[_keyFor(target, id)];
    if (expiry == null) return null;
    if (expiry == _forever) {
      return const MuteInfo(isForever: true);
    }
    return MuteInfo(
      isForever: false,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiry),
    );
  }

  String _keyFor(MuteTarget target, String id) {
    final prefix = target == MuteTarget.user ? 'u' : 'g';
    return '$prefix:$id';
  }

  Future<void> _load() async {
    _mutes.clear();
    final raw = _prefs?.getString(_storageKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is int) {
          _mutes[entry.key] = value;
        }
      }
    } catch (e) {
      print('Error loading notification mutes: $e');
    }
  }

  Future<void> _save() async {
    try {
      await _prefs?.setString(_storageKey, jsonEncode(_mutes));
    } catch (e) {
      print('Error saving notification mutes: $e');
    }
  }

  void _pruneExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiredKeys = <String>[];
    for (final entry in _mutes.entries) {
      if (entry.value != _forever && entry.value <= now) {
        expiredKeys.add(entry.key);
      }
    }
    if (expiredKeys.isEmpty) return;
    for (final key in expiredKeys) {
      _mutes.remove(key);
    }
    unawaited(_save());
  }
}
