import 'dart:convert';

class RoadmapTask {
  final String id;
  String description;
  String tag;
  bool isDone;

  RoadmapTask({
    required this.id,
    required this.description,
    required this.tag,
    this.isDone = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'description': description, 'tag': tag, 'isDone': isDone,
  };

  factory RoadmapTask.fromJson(Map<String, dynamic> json) => RoadmapTask(
    id: json['id'],
    description: json['description'],
    tag: json['tag'],
    isDone: json['isDone'] ?? false,
  );
}

class Milestone {
  String version;
  String title;
  List<RoadmapTask> tasks;

  Milestone({required this.version, required this.title, required this.tasks});

  Map<String, dynamic> toJson() => {
    'version': version, 'title': title, 'tasks': tasks.map((e) => e.toJson()).toList(),
  };

  factory Milestone.fromJson(Map<String, dynamic> json) => Milestone(
    version: json['version'],
    title: json['title'],
    tasks: (json['tasks'] as List).map((e) => RoadmapTask.fromJson(e)).toList(),
  );
}
