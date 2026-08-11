import 'package:flutter/widgets.dart';

/// Bottom-composer wrapper shared by the 1:1, group and self chat bodies.
///
/// The chat body is `Column [ Expanded(list), composer ]`: the composer is a
/// non-flex child, so with the keyboard open the app content is padded by the
/// full keyboard inset (PrysmApp) and the composer (reply preview + typing
/// bar + input row) can be taller than the body's remaining height and
/// overflow the outer Column. Constrain it to the available height and let it
/// scroll instead.
class PrysmConstrainedComposer extends StatelessWidget {
  const PrysmConstrainedComposer({
    required this.maxHeight,
    required this.composer,
    super.key,
  });

  /// The height the chat body can still give the composer (the body
  /// LayoutBuilder's `constraints.maxHeight`).
  final double maxHeight;

  /// The bottom composer column ([PrysmChatComposerColumn]).
  final Widget composer;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        reverse: true,
        child: composer,
      ),
    );
  }
}
