import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

/// Material-free text input using [EditableText].
class PrysmTextField extends StatefulWidget {
  const PrysmTextField({
    required this.controller,
    this.focusNode,
    this.hintText,
    this.labelText,
    this.onChanged,
    this.onSubmitted,
    this.minLines = 1,
    this.maxLines = 5,
    this.autofocus = false,
    this.enabled = true,
    this.obscureText = false,
    this.prefixIcon,
    this.suffixIcon,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final String? labelText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final int minLines;
  final int maxLines;
  final bool autofocus;
  final bool enabled;
  final bool obscureText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  @override
  State<PrysmTextField> createState() => _PrysmTextFieldState();
}

class _PrysmTextFieldState extends State<PrysmTextField> {
  late FocusNode _focusNode;
  bool _ownsFocus = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocus = true;
    }
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    if (_ownsFocus) _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
    widget.onChanged?.call(widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    final showHint =
        widget.hintText != null && widget.controller.text.isEmpty;

    final field = EditableText(
      controller: widget.controller,
      focusNode: _focusNode,
      style: style.bodyStyle.copyWith(
        color: widget.enabled ? tokens.textPrimary : tokens.textMuted,
      ),
      cursorColor: tokens.accent,
      backgroundCursorColor: tokens.textMuted,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      autofocus: widget.autofocus,
      readOnly: !widget.enabled,
      obscureText: widget.obscureText,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.labelText != null) ...[
          Text(widget.labelText!, style: style.captionStyle),
          const SizedBox(height: 6),
        ],
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceElevated,
            borderRadius: style.composerRadius,
            border: Border.all(
              color: _focusNode.hasFocus ? tokens.accent : tokens.outline,
              width: _focusNode.hasFocus ? 1.5 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                if (widget.prefixIcon != null) ...[
                  widget.prefixIcon!,
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (showHint)
                        Text(widget.hintText!, style: style.captionStyle),
                      field,
                    ],
                  ),
                ),
                if (widget.suffixIcon != null) widget.suffixIcon!,
              ],
            ),
          ),
        ),
      ],
    );
  }
}
