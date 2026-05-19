import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../models/roadmap_model.dart';
import '../vcs.dart';

class RoadmapManager {
  static File _getRoadmapFile(dynamic context) => 
      File(p.join(context.remoteRepoDir.path, 'roadmap.json'));

  static List<Milestone> load(dynamic context) {
    final file = _getRoadmapFile(context);
    if (!file.existsSync()) return [];
    try {
      final List decode = jsonDecode(file.readAsStringSync());
      return decode.map((e) => Milestone.fromJson(e)).toList();
    } on FormatException catch (fe) {
      print('❌ ${"Roadmap Syntax Error:".red} ${fe.message}');
      rethrow;
    } catch (_) {
      return [];
    }
  }

  static void save(dynamic context, List<Milestone> roadmap) {
    final file = _getRoadmapFile(context);
    final encoder = JsonEncoder.withIndent('  ');
    file.writeAsStringSync(encoder.convert(roadmap.map((e) => e.toJson()).toList()));
  }

  static void initializeTemplate(dynamic context) {
    final file = _getRoadmapFile(context);
    if (file.existsSync()) return;

    final template = [
      {
        "version": "1.0.0-Beta",
        "title": "Project Foundation & Core Features",
        "tasks": [
          {"id": "TSK-001", "description": "Setup local database architecture and tables", "tag": "DB", "isDone": true},
          {"id": "TSK-002", "description": "Implement user authentication and JWT tokens", "tag": "SEC", "isDone": false},
          {"id": "TSK-003", "description": "Design core CLI commands layout", "tag": "UX", "isDone": false}
        ]
      },
      {
        "version": "1.1.0-Release",
        "title": "Polishing & Ecosystem Expansion",
        "tasks": [
          {"id": "TSK-004", "description": "Optimize query indexation performance", "tag": "PERF", "isDone": false},
          {"id": "TSK-005", "description": "Write comprehensive unit testing suite", "tag": "QA", "isDone": false}
        ]
      }
    ];

    final encoder = JsonEncoder.withIndent('  ');
    file.writeAsStringSync(encoder.convert(template));
  }
}