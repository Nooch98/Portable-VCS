enum ChangeKind { added, modified, deleted }

class FileChange {
  final ChangeKind kind;
  final String path;

  FileChange(this.kind, this.path);

  String toTag() {
    switch (kind) {
      case ChangeKind.added:
        return '[N] $path';
      case ChangeKind.modified:
        return '[M] $path';
      case ChangeKind.deleted:
        return '[D] $path';
    }
  }
}
