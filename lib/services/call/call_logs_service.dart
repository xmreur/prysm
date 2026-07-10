import 'dart:async';

import 'package:prysm/database/call_logs_db.dart';

class CallLogsService {
  static final CallLogsService _instance = CallLogsService._internal();
  factory CallLogsService() => _instance;
  CallLogsService._internal();

  static CallLogsService get instance => _instance;

  final _controller = StreamController<void>.broadcast();

  Stream<void> get onChanged => _controller.stream;

  Future<List<CallLog>> getLogs({
    String? peerOnion,
    int limit = 100,
    int offset = 0,
  }) async {
    return CallLogsDb.getLogs(
      peerOnion: peerOnion,
      limit: limit,
      offset: offset,
    );
  }

  Future<void> deleteLog(String callId) async {
    await CallLogsDb.deleteLog(callId);
    _notify();
  }

  Future<void> deleteAllLogs() async {
    await CallLogsDb.deleteAllLogs();
    _notify();
  }

  void notifyChanged() {
    _notify();
  }

  void _notify() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }
}
