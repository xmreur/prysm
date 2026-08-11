import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';
import 'package:prysm/ui/core/prysm_text_selection.dart';

class PrysmSearchField extends StatefulWidget {
  const PrysmSearchField({
    required this.controller,
    this.hintText = 'Search',
    this.onChanged,
    this.onClear,
    super.key,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  @override
  State<PrysmSearchField> createState() => _PrysmSearchFieldState();
}

class _PrysmSearchFieldState extends State<PrysmSearchField> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final showHint =
        widget.hintText.isNotEmpty && widget.controller.text.isEmpty;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: tokens.surfaceElevated,
        borderRadius: style.composerRadius,
      ),
      padding: const EdgeInsets.symmetric(horizontal: PrysmTokens.spacing12),
      child: Row(
        children: [
          Icon(PrysmIcons.search, size: 20, color: tokens.textMuted),
          const SizedBox(width: PrysmTokens.spacing8),
          Expanded(
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                if (showHint)
                  Text(widget.hintText, style: style.captionStyle),
                PrysmEditableText(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  style: style.bodyStyle.copyWith(color: tokens.textPrimary),
                  cursorColor: tokens.accent,
                  backgroundCursorColor: tokens.textMuted,
                  selectionColor: tokens.accent.withValues(alpha: 0.40),
                  maxLines: 1,
                  onChanged: widget.onChanged,
                ),
              ],
            ),
          ),
          if (widget.controller.text.isNotEmpty && widget.onClear != null)
            PrysmClearButton(onPressed: widget.onClear!),
        ],
      ),
    );
  }
}

class PrysmClearButton extends StatelessWidget {
  const PrysmClearButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return PrysmPressable(
      onTap: onPressed,
      child: Icon(PrysmIcons.close, size: 18, color: tokens.textMuted),
    );
  }
}
