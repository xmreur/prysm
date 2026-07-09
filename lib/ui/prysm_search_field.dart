import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';

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
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
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
            child: PrysmTextField(
              controller: widget.controller,
              hintText: widget.hintText,
              onChanged: widget.onChanged,
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
