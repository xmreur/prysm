import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:prysm/util/qr_platform.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  MobileScannerController? _controller;
  PermissionStatus _permissionStatus = PermissionStatus.denied;
  bool _checkingPermission = true;
  bool _hasScanned = false;
  TorchState _torchState = TorchState.off;

  @override
  void initState() {
    super.initState();
    if (QrPlatform.isScanSupported) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
      );
      _controller!.addListener(() {
        if (!mounted) return;
        setState(() => _torchState = _controller!.value.torchState);
      });
      _checkPermission();
    } else {
      setState(() {
        _checkingPermission = false;
      });
    }
  }

  Future<void> _checkPermission() async {
    final status = await Permission.camera.status;
    if (status.isGranted) {
      if (mounted) {
        setState(() {
          _permissionStatus = status;
          _checkingPermission = false;
        });
      }
    } else {
      final reqStatus = await Permission.camera.request();
      if (mounted) {
        setState(() {
          _permissionStatus = reqStatus;
          _checkingPermission = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!QrPlatform.isScanSupported) {
      return PrysmPage(
        title: 'QR Scanner',
        leading: PrysmIconButton(
          icon: PrysmIcons.arrowBack,
          onPressed: () => Navigator.pop(context),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'QR Scanner is only supported on mobile devices (Android/iOS).',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }

    if (_checkingPermission) {
      return const ColoredBox(
        color: Color(0xFF000000),
        child: Center(child: PrysmProgressIndicator()),
      );
    }

    if (!_permissionStatus.isGranted) {
      return ColoredBox(
        color: const Color(0xFF000000),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: PrysmIconButton(
                  icon: PrysmIcons.arrowBack,
                  color: const Color(0xFFFFFFFF),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        PrysmIcons.cameraAltOutlined,
                        color: Color(0x54FFFFFF),
                        size: 64,
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Camera Permission Required',
                        style: TextStyle(
                          color: Color(0xFFFFFFFF),
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Prysm needs camera access to scan QR codes for adding contacts.',
                        style: TextStyle(
                          color: Color(0xB3FFFFFF),
                          fontSize: 15,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      PrysmButton(
                        label: 'Open Settings',
                        onPressed: openAppSettings,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ColoredBox(
      color: const Color(0xFF000000),
      child: Stack(
        children: [
          MobileScanner(
            controller: _controller!,
            onDetect: (capture) {
              if (_hasScanned) return;
              final barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                final value = barcode.rawValue;
                if (value != null && value.trim().isNotEmpty) {
                  _hasScanned = true;
                  Navigator.pop(context, value.trim());
                  break;
                }
              }
            },
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: QrScannerOverlayShape(
                  borderColor: context.prysmStyle.tokens.accent,
                  borderRadius: 12,
                  borderLength: 30,
                  borderWidth: 6,
                  cutOutSize: MediaQuery.of(context).size.width * 0.7,
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            right: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                PrysmIconButton(
                  icon: PrysmIcons.arrowBack,
                  color: const Color(0xFFFFFFFF),
                  onPressed: () => Navigator.pop(context),
                ),
                const Text(
                  'Scan Contact QR',
                  style: TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  children: [
                    PrysmIconButton(
                      icon: _torchState == TorchState.on
                          ? PrysmIcons.flashOn
                          : PrysmIcons.flashOff,
                      color: _torchState == TorchState.on
                          ? const Color(0xFFFFFF00)
                          : const Color(0xFFFFFFFF),
                      onPressed: () => _controller?.toggleTorch(),
                    ),
                    PrysmIconButton(
                      icon: PrysmIcons.flipCameraAndroid,
                      color: const Color(0xFFFFFFFF),
                      onPressed: () => _controller?.switchCamera(),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Positioned(
            bottom: 60,
            left: 24,
            right: 24,
            child: Text(
              'Align the QR code inside the frame to scan.',
              style: TextStyle(
                color: Color(0xB3FFFFFF),
                fontSize: 14,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class QrScannerOverlayShape extends ShapeBorder {
  final Color borderColor;
  final double borderWidth;
  final double borderLength;
  final double borderRadius;
  final double cutOutSize;

  const QrScannerOverlayShape({
    this.borderColor = const Color(0xFF2196F3),
    this.borderWidth = 4.0,
    this.borderLength = 20.0,
    this.borderRadius = 8.0,
    this.cutOutSize = 250.0,
  });

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..addOval(
        Rect.fromCircle(
          center: rect.center,
          radius: cutOutSize / 2,
        ),
      );
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRect(rect);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final paint = Paint()
      ..color = const Color(0x54000000)
      ..style = PaintingStyle.fill;

    final cutOutRect = Rect.fromCenter(
      center: rect.center,
      width: cutOutSize,
      height: cutOutSize,
    );

    final backgroundPath = Path()
      ..addRect(rect)
      ..addRect(cutOutRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(backgroundPath, paint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.round;

    final halfWidth = cutOutSize / 2;
    final center = rect.center;

    final left = center.dx - halfWidth;
    final right = center.dx + halfWidth;
    final top = center.dy - halfWidth;
    final bottom = center.dy + halfWidth;

    canvas.drawPath(
      Path()
        ..moveTo(left, top + borderLength)
        ..lineTo(left, top + borderRadius)
        ..quadraticBezierTo(left, top, left + borderRadius, top)
        ..lineTo(left + borderLength, top),
      borderPaint,
    );

    canvas.drawPath(
      Path()
        ..moveTo(right - borderLength, top)
        ..lineTo(right - borderRadius, top)
        ..quadraticBezierTo(right, top, right, top + borderRadius)
        ..lineTo(right, top + borderLength),
      borderPaint,
    );

    canvas.drawPath(
      Path()
        ..moveTo(left, bottom - borderLength)
        ..lineTo(left, bottom - borderRadius)
        ..quadraticBezierTo(left, bottom, left + borderRadius, bottom)
        ..lineTo(left + borderLength, bottom),
      borderPaint,
    );

    canvas.drawPath(
      Path()
        ..moveTo(right - borderLength, bottom)
        ..lineTo(right - borderRadius, bottom)
        ..quadraticBezierTo(right, bottom, right, bottom - borderRadius)
        ..lineTo(right, bottom - borderLength),
      borderPaint,
    );
  }

  @override
  ShapeBorder scale(double t) {
    return QrScannerOverlayShape(
      borderColor: borderColor,
      borderWidth: borderWidth * t,
      borderLength: borderLength * t,
      borderRadius: borderRadius * t,
      cutOutSize: cutOutSize * t,
    );
  }
}
