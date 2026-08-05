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
          // Inert by construction: this window never starts a Tor daemon.
          // DetachedChatShell only forwards this manager to the chat widgets,
          // which connect through the main window's already-running Tor, so
          // the empty password is never used. This build() is synchronous and
          // the real per-install secret (CryptoKeyStore.torControlPassword(),
          // an async secure-storage read) cannot be fetched here without
          // restructuring the widget. Before any code path in this window may
          // call startTor(), construction must move behind an async gate —
          // e.g. a FutureBuilder resolving createTorManager() from
          // lib/app/tor_connection_controller.dart, the only place Tor is
          // actually started with the real password.
          controlPassword: '',
        ),
        settings: settings,
      ),
    );
  }
}
