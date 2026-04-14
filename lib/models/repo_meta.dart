import 'dart:io';
import 'package:vcs/models/snapshot_log_entry.dart';

class RemoteRepoInfo {
  final Directory repoDir;
  final RepoMeta meta;

  RemoteRepoInfo({
    required this.repoDir,
    required this.meta,
  });
}

class RepoMeta {
  final String repoId;
  final String projectName;
  final String createdAt;
  final String updatedAt;
  final int formatVersion;
  final List<SnapshotLogEntry> logs;

  RepoMeta({
    required this.repoId,
    required this.projectName,
    required this.createdAt,
    required this.updatedAt,
    required this.formatVersion,
    required this.logs,
  });

  factory RepoMeta.fromJson(Map<String, dynamic> json) {
    return RepoMeta(
      repoId: json['repo_id'] as String,
      projectName: json['project_name'] as String,
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
      formatVersion: json['format_version'] as int,
      logs: ((json['logs'] as List?) ?? [])
          .map((e) => SnapshotLogEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'repo_id': repoId,
        'project_name': projectName,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'format_version': formatVersion,
        'logs': logs.map((e) => e.toJson()).toList(),
      };

  RepoMeta copyWith({
    String? updatedAt,
    List<SnapshotLogEntry>? logs,
  }) {
    return RepoMeta(
      repoId: repoId,
      projectName: projectName,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      formatVersion: formatVersion,
      logs: logs ?? this.logs,
    );
  }
}
