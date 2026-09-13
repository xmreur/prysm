/// Half-block text rendering of a QR code, for the `pair-link` output.
///
/// Pure Dart on top of package:qr (no Flutter): the operator scans the block
/// off the terminal, or pastes the link text next to it.
library;

import 'package:qr/qr.dart';

/// Renders [data] as a QR code (error correction M, auto version) with
/// half-block characters: two module rows per text row, quiet zone of
/// 2 modules. Dark modules are full blocks (`█`/`▀`/`▄`), light modules are
/// spaces — on a dark terminal this reads light-on-dark, which QR readers
/// tolerate.
String renderQrText(String data) {
  final image = QrImage(
    QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    ),
  );
  final n = image.moduleCount;
  const quiet = 2;
  final size = n + quiet * 2;
  bool dark(int x, int y) {
    if (x < quiet || y < quiet || x >= quiet + n || y >= quiet + n) {
      return false;
    }
    return image.isDark(y - quiet, x - quiet);
  }

  final out = StringBuffer();
  for (var y = 0; y < size; y += 2) {
    for (var x = 0; x < size; x++) {
      final top = dark(x, y);
      final bottom = y + 1 < size && dark(x, y + 1);
      out.write(top ? (bottom ? '█' : '▀') : (bottom ? '▄' : ' '));
    }
    out.writeln();
  }
  return out.toString();
}
