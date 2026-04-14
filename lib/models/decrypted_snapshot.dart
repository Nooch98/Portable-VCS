import 'dart:typed_data';

class DecryptedSnapshot {
  final Uint8List zipBytes;
  final Map<String, String> fingerprint;
  final String? message;
  final String? author;
  final String? createdAt;

  DecryptedSnapshot({
    required this.zipBytes,
    required this.fingerprint,
    required this.message,
    required this.author,
    required this.createdAt,
  });
}
