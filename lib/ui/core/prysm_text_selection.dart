import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

/// Material-free text selection for Prysm's inputs.
///
/// A bare [EditableText] paints no selection highlight, grows no drag handles
/// and opens no context menu: `selectionColor`, `selectionControls` and
/// `contextMenuBuilder` all default to null, and `RenderEditable`'s built-in
/// long-press recogniser only calls `selectWord`. The result on a phone is a
/// long press that appears to do nothing — no visible selection, no
/// copy/paste menu.
///
/// [PrysmEditableText] supplies the three missing pieces the way
/// `TextField`/`CupertinoTextField` do, but drawn from [PrysmTokens] instead of
/// a Material theme: a [TextSelectionGestureDetectorBuilder] for the gestures,
/// [PrysmTextSelectionControls] for the handles, and
/// [prysmEditableTextContextMenuBuilder] for the toolbar.

/// Diameter of a selection handle's circular head.
const double _kHandleSize = 20.0;

/// Gap kept between the toolbar and the screen edges.
const double _kToolbarScreenPadding = 8.0;

/// Gap between the toolbar and the top of the selection.
const double _kToolbarContentDistance = 8.0;

/// Gap between the toolbar and the bottom of the selection. Larger than the
/// distance above so the toolbar clears the handles it would otherwise cover.
const double _kToolbarContentDistanceBelow = _kHandleSize + 8.0;

// ============================================================ handles

/// Prysm-styled drag handles for a text selection.
///
/// Mixes in [TextSelectionHandleControls] so [EditableText] routes the toolbar
/// through [EditableText.contextMenuBuilder] instead of the deprecated
/// `buildToolbar`.
class PrysmTextSelectionControls extends TextSelectionControls
    with TextSelectionHandleControls {
  @override
  Size getHandleSize(double textLineHeight) =>
      const Size(_kHandleSize, _kHandleSize);

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) {
    final tokens = context.prysmStyle.tokens;
    final handle = SizedBox.square(
      dimension: _kHandleSize,
      child: CustomPaint(
        painter: _PrysmHandlePainter(color: tokens.accent),
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.translucent,
        ),
      ),
    );

    // The painter draws a disc with a square corner in its top-left quadrant:
    // a teardrop pointing up-left. Each handle is anchored by a different
    // corner (see getHandleAnchor), so the rotation has to put the point on
    // the anchored corner or the teardrop aims away from the caret it marks.
    return switch (type) {
      // anchored top-right -> point must be top-right
      TextSelectionHandleType.left =>
        Transform.rotate(angle: math.pi / 2.0, child: handle),
      // anchored top-left -> the painter already points there
      TextSelectionHandleType.right => handle,
      // anchored top-centre -> point straight up
      TextSelectionHandleType.collapsed =>
        Transform.rotate(angle: math.pi / 4.0, child: handle),
    };
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) {
    return switch (type) {
      TextSelectionHandleType.left => const Offset(_kHandleSize, 0),
      TextSelectionHandleType.right => Offset.zero,
      TextSelectionHandleType.collapsed => const Offset(_kHandleSize / 2, -4),
    };
  }
}

/// The single instance used by every Prysm input.
final TextSelectionControls prysmTextSelectionControls =
    PrysmTextSelectionControls();

class _PrysmHandlePainter extends CustomPainter {
  const _PrysmHandlePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final paint = Paint()..color = color;
    canvas.drawCircle(Offset(radius, radius), radius, paint);
    canvas.drawRect(Rect.fromLTWH(0, 0, radius, radius), paint);
  }

  @override
  bool shouldRepaint(_PrysmHandlePainter oldDelegate) =>
      color != oldDelegate.color;
}

// ============================================================ context menu

/// [EditableText.contextMenuBuilder] for every Prysm input.
Widget prysmEditableTextContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return PrysmTextSelectionToolbar(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: editableTextState.contextMenuButtonItems,
  );
}

/// The cut/copy/paste/select-all bar, positioned against a selection.
class PrysmTextSelectionToolbar extends StatelessWidget {
  const PrysmTextSelectionToolbar({
    required this.anchors,
    required this.buttonItems,
    super.key,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  static String labelFor(ContextMenuButtonItem item) {
    return item.label ??
        switch (item.type) {
          ContextMenuButtonType.cut => 'Cut',
          ContextMenuButtonType.copy => 'Copy',
          ContextMenuButtonType.paste => 'Paste',
          ContextMenuButtonType.selectAll => 'Select all',
          ContextMenuButtonType.delete => 'Delete',
          ContextMenuButtonType.lookUp => 'Look up',
          ContextMenuButtonType.searchWeb => 'Search web',
          ContextMenuButtonType.share => 'Share',
          ContextMenuButtonType.liveTextInput => 'Scan text',
          ContextMenuButtonType.custom => 'Action',
        };
  }

  @override
  Widget build(BuildContext context) {
    if (buttonItems.isEmpty) return const SizedBox.shrink();

    final style = context.prysmStyle;
    final tokens = style.tokens;
    final media = MediaQuery.of(context);
    final paddingAbove = media.padding.top + _kToolbarScreenPadding;

    // Anchors arrive in global coordinates; the Padding below shifts the
    // layout origin, so the delegate needs them in its own local space.
    final localAdjustment = Offset(_kToolbarScreenPadding, paddingAbove);
    final anchorAbove =
        anchors.primaryAnchor - const Offset(0, _kToolbarContentDistance);
    final anchorBelow = anchors.secondaryAnchor == null
        ? anchors.primaryAnchor
        : anchors.secondaryAnchor! +
            const Offset(0, _kToolbarContentDistanceBelow);

    final children = <Widget>[];
    for (var i = 0; i < buttonItems.length; i++) {
      if (i > 0) {
        children.add(
          Container(width: 1, height: 20, color: tokens.divider),
        );
      }
      final item = buttonItems[i];
      children.add(
        PrysmPressable(
          onTap: item.onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Text(
              labelFor(item),
              style: style.bodyStyle.copyWith(
                color: tokens.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _kToolbarScreenPadding,
        paddingAbove,
        _kToolbarScreenPadding,
        _kToolbarScreenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove: anchorAbove - localAdjustment,
          anchorBelow: anchorBelow - localAdjustment,
        ),
        child: ConstrainedBox(
          // Wrap + a hard cap is what keeps a long menu (Android contributes
          // extra PROCESS_TEXT entries) from overflowing instead of folding
          // onto a second line.
          constraints: BoxConstraints(
            maxWidth: media.size.width - 2 * _kToolbarScreenPadding,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceElevated,
              borderRadius: BorderRadius.circular(PrysmTokens.radiusCard),
              border: Border.all(color: tokens.outline),
              boxShadow: style.bubbleShadow,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(PrysmTokens.radiusCard),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================ editable text

/// [EditableText] with Prysm's selection gestures, handles and context menu.
///
/// Both [PrysmTextField] and [PrysmSearchField] build on this, so the wiring
/// lives in one place: duplicating it would be a second convention beside an
/// existing one, and the halves would drift.
class PrysmEditableText extends StatefulWidget {
  const PrysmEditableText({
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.cursorColor,
    required this.backgroundCursorColor,
    required this.selectionColor,
    this.minLines = 1,
    this.maxLines = 1,
    this.autofocus = false,
    this.readOnly = false,
    this.obscureText = false,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final Color cursorColor;
  final Color backgroundCursorColor;
  final Color selectionColor;
  final int minLines;
  final int maxLines;
  final bool autofocus;
  final bool readOnly;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PrysmEditableText> createState() => _PrysmEditableTextState();
}

class _PrysmEditableTextState extends State<PrysmEditableText>
    implements TextSelectionGestureDetectorBuilderDelegate {
  late final TextSelectionGestureDetectorBuilder _gestureBuilder;
  bool _showSelectionHandles = false;

  // TextSelectionGestureDetectorBuilderDelegate
  @override
  final GlobalKey<EditableTextState> editableTextKey =
      GlobalKey<EditableTextState>();

  /// Force press is an iOS 3D-Touch affordance no shipping device exposes.
  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => !widget.obscureText && !widget.readOnly;

  @override
  void initState() {
    super.initState();
    _gestureBuilder = TextSelectionGestureDetectorBuilder(delegate: this);
  }

  /// Whether the handles should be visible for a selection changed by [cause].
  ///
  /// Keeping them off for keyboard-driven changes is what stops handles from
  /// appearing while the user types.
  bool _shouldShowSelectionHandles(SelectionChangedCause? cause) {
    if (!_gestureBuilder.shouldShowSelectionToolbar ||
        !_gestureBuilder.shouldShowSelectionHandles) {
      return false;
    }
    if (cause == SelectionChangedCause.keyboard) return false;
    if (!selectionEnabled) return false;
    if (cause == SelectionChangedCause.longPress ||
        cause == SelectionChangedCause.stylusHandwriting) {
      return true;
    }
    return widget.controller.text.isNotEmpty;
  }

  void _handleSelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    final willShow = _shouldShowSelectionHandles(cause);
    if (willShow != _showSelectionHandles) {
      setState(() => _showSelectionHandles = willShow);
    }
    if (cause == SelectionChangedCause.longPress) {
      editableTextKey.currentState?.bringIntoView(selection.extent);
    }
  }

  /// Tapping a collapsed handle toggles the toolbar — the gesture that lets a
  /// user paste without selecting anything first.
  void _handleSelectionHandleTapped() {
    if (widget.controller.selection.isCollapsed) {
      editableTextKey.currentState?.toggleToolbar();
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = EditableText(
      key: editableTextKey,
      controller: widget.controller,
      focusNode: widget.focusNode,
      style: widget.style,
      cursorColor: widget.cursorColor,
      backgroundCursorColor: widget.backgroundCursorColor,
      selectionColor: widget.selectionColor,
      selectionControls: selectionEnabled ? prysmTextSelectionControls : null,
      contextMenuBuilder: prysmEditableTextContextMenuBuilder,
      showSelectionHandles: _showSelectionHandles,
      onSelectionChanged: _handleSelectionChanged,
      onSelectionHandleTapped: _handleSelectionHandleTapped,
      enableInteractiveSelection: selectionEnabled,
      // The gesture detector below owns tap and long press; leaving
      // RenderEditable's own recognisers on would make the two fight over the
      // same pointer.
      rendererIgnoresPointer: true,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      obscureText: widget.obscureText,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
    );

    return _gestureBuilder.buildGestureDetector(
      behavior: HitTestBehavior.translucent,
      child: editable,
    );
  }
}
