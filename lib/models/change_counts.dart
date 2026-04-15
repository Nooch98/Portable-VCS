class ChangeCounts {
  final int added;
  final int modified;
  final int deleted;

  ChangeCounts({
    required this.added,
    required this.modified,
    required this.deleted,
  });

  int get total => added + modified + deleted;
}
