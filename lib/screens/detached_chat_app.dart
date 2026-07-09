import 'package:flutter/widgets.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/screens/detached_chat_shell.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/tor_service.dart';

/// Minimal app shell for a pop-out chat window.
class DetachedChatApp extends StatelessWidget {
  final DetachedChatLaunch launch;

  const DetachedChatApp({required this.launch, super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService();
    return PrysmApp(
      themePalette: launch.themeIndex,
      appearance: settings.appearance,
      title: launch.title,
      home: DetachedChatShell(
        launch: launch,
        keyManager: KeyManager(),
        torManager: TorManager(
          torPath: '',
          dataDir: '',
        ),
        settings: settings,
      ),
    );
  }
}
