class FingerprintChange {
  final String path;
  final String? oldHash;
  final String? newHash;

  FingerprintChange({
    required this.path,
    this.oldHash,
    this.newHash,
  });

  String toTag() {
    if (oldHash == null) return '+';
    if (newHash == null) return '-';
    return '~';
  }
}
