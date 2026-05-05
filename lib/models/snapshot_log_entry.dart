import 'package:vcs/models/snapshot_notes.dart';

class SnapshotLogEntry {
  final String id;
  final String message;
  final String? author;
  final String createdAt;
  final String fileName;
  final List<String> changeSummary;
  final String? hash;
  final List<SnapshotNote> notes;
  final String? parentId;

  SnapshotLogEntry({
    required this.id,
    required this.message,
    required this.author,
    required this.createdAt,
    required this.fileName,
    required this.changeSummary,
    this.hash,
    this.notes = const [],
    this.parentId,
  });

  factory SnapshotLogEntry.fromJson(Map<String, dynamic> json) {
    return SnapshotLogEntry(
      id: json['id'] as String,
      message: json['message'] as String,
      author: json['author']?.toString(),
      createdAt: json['created_at'] as String,
      fileName: json['file_name'] as String,
      changeSummary: ((json['change_summary'] as List?) ?? [])
          .map((e) => e.toString())
          .toList(),
      hash: json['hash']?.toString(),
      notes: ((json['notes'] as List?) ?? [])
          .map((e) => SnapshotNote.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      parentId: json['parent_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'message': message,
        'author': author,
        'created_at': createdAt,
        'file_name': fileName,
        'change_summary': changeSummary,
        'hash': hash,
        'notes': notes.map((e) => e.toJson()).toList(),
        'parent_id': parentId,
      };

  bool get hasIntegrityData => hash != null && hash!.isNotEmpty;

  SnapshotLogEntry copyWith({
    String? message,
    List<SnapshotNote>? notes,
    String? parentId,
  }) {
    return SnapshotLogEntry(
      id: id,
      message: message ?? this.message,
      author: author,
      createdAt: createdAt,
      fileName: fileName,
      changeSummary: changeSummary,
      hash: hash,
      notes: notes ?? this.notes,
      parentId: parentId ?? this.parentId,
    );
  }

  SnapshotLogEntry copyWithNotes(List<SnapshotNote> newNotes) {
    return copyWith(notes: newNotes);
  }

  SnapshotLogEntry copyWithNote(SnapshotNote newNote) {
    return copyWith(notes: [...notes, newNote]);
  }
}
