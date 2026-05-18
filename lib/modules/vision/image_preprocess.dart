import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Long edge (px) for frames sent to Gemma's vision encoder. 512 keeps
/// activation memory well under the ~50 MB spike budget on 3 GB phones.
const int kVisionLongEdgePx = 512;

/// Resize a captured JPEG to a bounded long edge and re-encode.
///
/// Strips oversized EXIF/orientation payloads and caps decode memory.
Uint8List preprocessJpegForVision(Uint8List jpegBytes) {
  final decoded = img.decodeJpg(jpegBytes);
  if (decoded == null) {
    return jpegBytes;
  }
  final longEdge =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longEdge <= kVisionLongEdgePx) {
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
  }
  final scale = kVisionLongEdgePx / longEdge;
  final resized = img.copyResize(
    decoded,
    width: (decoded.width * scale).round(),
    height: (decoded.height * scale).round(),
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(img.encodeJpg(resized, quality: 90));
}
