import 'package:flutter/material.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/screens/detached_chat_shell.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/theme_manager.dart';
import 'package:prysm/util/tor_service.dart';

/// Minimal app shell for a pop-out chat window.
class DetachedChatApp extends StatelessWidget {
  final DetachedChatLaunch launch;

  const DetachedChatApp({required this.launch, super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: launch.title,
      theme: ThemeManager.getTheme(launch.themeIndex),
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
