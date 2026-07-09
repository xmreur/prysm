import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';

Future<bool?> showPrysmConfirmDialog({
  required BuildContext context,
  required String title,
  required Widget content,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  PrysmButtonVariant confirmVariant = PrysmButtonVariant.primary,
}) {
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: const Color(0x80000000),
    pageBuilder: (context, animation, secondaryAnimation) {
      return Center(
        child: PrysmDialog(
          title: title,
          content: content,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          confirmVariant: confirmVariant,
          onConfirm: () => Navigator.of(context).pop(true),
          onCancel: () => Navigator.of(context).pop(false),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

Future<T?> showPrysmDialog<T>({
  required BuildContext context,
  required String title,
  required Widget content,
  String? confirmLabel,
  String? cancelLabel,
  VoidCallback? onConfirm,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: const Color(0x80000000),
    pageBuilder: (context, animation, secondaryAnimation) {
      return Center(
        child: PrysmDialog(
          title: title,
          content: content,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          onConfirm: onConfirm,
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

class PrysmDialog extends StatelessWidget {
  const PrysmDialog({
    required this.title,
    required this.content,
    this.confirmLabel,
    this.cancelLabel,
    this.onConfirm,
    this.onCancel,
    this.confirmVariant = PrysmButtonVariant.primary,
    super.key,
  });

  final String title;
  final Widget content;
  final String? confirmLabel;
  final String? cancelLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final PrysmButtonVariant confirmVariant;

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final tokens = style.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: style.headlineStyle),
                const SizedBox(height: 16),
                content,
                if (confirmLabel != null || cancelLabel != null) ...[
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (cancelLabel != null)
                        PrysmPressable(
                          onTap: () {
                            if (onCancel != null) {
                              onCancel!();
                            } else {
                              Navigator.of(context).pop();
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(cancelLabel!,
                                style: style.bodyStyle),
                          ),
                        ),
                      if (confirmLabel != null) ...[
                        const SizedBox(width: 8),
                        PrysmButton(
                          label: confirmLabel!,
                          variant: confirmVariant,
                          onPressed: () {
                            if (onConfirm != null) {
                              onConfirm!();
                            } else {
                              Navigator.of(context).pop();
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
    );
  }
}
