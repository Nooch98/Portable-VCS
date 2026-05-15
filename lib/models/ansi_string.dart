class AnsiString {
  final String raw;
  late final String plain;
  late final int visualLength;

  AnsiString(this.raw) {
    plain = raw.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');
    visualLength = plain.length;
  }

  String padRight(int width) => raw + (' ' * (width - visualLength));
}
