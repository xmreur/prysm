import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A [CustomPainter] that paints a pre-generated [QrImage] once.
/// No mask search or data encoding — pure rendering.
const double _qrGapSize = 0.25;

class _CachedQrPainter extends CustomPainter {
  final QrImage qrImage;

  _CachedQrPainter({required this.qrImage});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide == 0) return;

    final container = size.shortestSide;
    final count = qrImage.moduleCount;
    final gapTotal = (count - 1) * _qrGapSize;
    final rawPx = (container - gapTotal) / count;
    final px = (rawPx * 2).roundToDouble() / 2;
    final inner = px * count + gapTotal;
    final inset = (container - inner) / 2;

    final dark = Paint()..color = Colors.black;

    for (var y = 0; y < count; y++) {
      for (var x = 0; x < count; x++) {
        if (qrImage.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(
              inset + x * (px + _qrGapSize),
              inset + y * (px + _qrGapSize),
              px,
              px,
            ),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CachedQrPainter old) => false;
}

/// Renders a scannable QR code for a Base58-encoded Prysm ID.
///
/// The QR matrix and the optimal mask are generated **once** in [initState].
/// Subsequent rebuilds only paint the cached image — no re-encoding, no
/// mask search, no heavy computation on the UI thread.
class PrysmIdQrCode extends StatefulWidget {
  final String data;
  final double size;

  const PrysmIdQrCode({
    required this.data,
    this.size = 160,
    super.key,
  });

  @override
  State<PrysmIdQrCode> createState() => _PrysmIdQrCodeState();
}

class _PrysmIdQrCodeState extends State<PrysmIdQrCode> {
  late final _CachedQrPainter _painter;

  @override
  void initState() {
    super.initState();
    final qrCode = QrCode.fromData(
      data: widget.data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qrCode);
    _painter = _CachedQrPainter(qrImage: qrImage);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(child: Text('ID not available')),
      );
    }

    return RepaintBoundary(
      child: Container(
        width: widget.size,
        height: widget.size,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: CustomPaint(painter: _painter),
      ),
    );
  }
}

void showPrysmIdQrDialog(BuildContext context, String encodedId) {
  showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      title: const Text('My QR Code'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Share this QR code with others so they can add you as a contact.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            PrysmIdQrCode(data: encodedId, size: 200),
            const SizedBox(height: 12),
            SelectableText(
              encodedId,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: encodedId));
            ScaffoldMessenger.of(dialogContext).showSnackBar(
              const SnackBar(content: Text('ID copied to clipboard')),
            );
          },
          child: const Text('Copy ID'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
