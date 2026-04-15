enum DiffLineType {
  context,
  added,
  removed,
}

class DiffLine {
  final String text;
  final DiffLineType type;

  DiffLine(this.text, this.type);

  factory DiffLine.context(String text) => DiffLine(text, DiffLineType.context);
  factory DiffLine.added(String text) => DiffLine(text, DiffLineType.added);
  factory DiffLine.removed(String text) => DiffLine(text, DiffLineType.removed);
}
