class SnapshotLogEntry {
  final String id;
  final String message;
  final String? author;
  final String createdAt;
  final String fileName;
  final List<String> changeSummary;

  SnapshotLogEntry({
    required this.id,
    required this.message,
    required this.author,
    required this.createdAt,
    required this.fileName,
    required this.changeSummary,
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
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'message': message,
        'author': author,
        'created_at': createdAt,
        'file_name': fileName,
        'change_summary': changeSummary,
      };
}
