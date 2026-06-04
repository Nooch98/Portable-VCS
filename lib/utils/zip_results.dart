import 'dart:typed_data';

class ZipResult {
  final Uint8List bytes;
  final Map<String, String> origins;
  ZipResult(this.bytes, this.origins);
}