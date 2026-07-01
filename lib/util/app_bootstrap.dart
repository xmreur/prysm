import 'package:prysm/models/detached_chat_launch.dart';

/// Whether startup should query [desktop_multi_window] for engine arguments.
bool shouldUseDetachedWindowBootstrap({required bool isDesktop}) => isDesktop;

typedef ReadEngineArguments = Future<String?> Function();

/// Routes startup to the main app or a detached chat window (desktop only).
Future<void> bootstrapApp({
  required bool isDesktop,
  required ReadEngineArguments readEngineArguments,
  required Future<void> Function() runMainApp,
  required Future<void> Function(DetachedChatLaunch launch) runDetachedApp,
}) async {
  if (isDesktop) {
    final args = await readEngineArguments();
    final launch = DetachedChatLaunch.parse(args);
    if (!launch.isMain) {
      await runDetachedApp(launch);
      return;
    }
  }
  await runMainApp();
}
