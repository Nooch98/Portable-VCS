class MergeReport {
  final String baseSnapshotId;
  final String targetSnapshotId;
  final List<String> safeFiles;
  final List<MergeConflict> conflicts;

  MergeReport({
    required this.baseSnapshotId,
    required this.targetSnapshotId,
    this.safeFiles = const [],
    this.conflicts = const [],
  });

  bool get hasConflicts => conflicts.isNotEmpty;
}

class MergeConflict {
  final String filePath;
  final List<String> conflictedScopes;

  MergeConflict({required this.filePath, this.conflictedScopes = const []});
}
