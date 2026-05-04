class SnapshotNote {
  final String text;
  final String? author;
  final String createdAt;

  SnapshotNote({
    required this.text,
    this.author,
    required this.createdAt,
  });

  factory SnapshotNote.fromJson(Map<String, dynamic> json) {
    return SnapshotNote(
      text: json['text'] as String,
      author: json['author']?.toString(),
      createdAt: json['created_at'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        'author': author,
        'created_at': createdAt,
      };
}
