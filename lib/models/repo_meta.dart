import 'dart:io';
import 'dart:math';
import 'package:vcs/models/snapshot_log_entry.dart';
import 'package:vcs/models/track_state.dart';

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

  final String activeTrack;
  final Map<String, TrackState> tracks;

  RepoMeta({
    required this.repoId,
    required this.projectName,
    required this.createdAt,
    required this.updatedAt,
    required this.formatVersion,
    required this.activeTrack,
    required this.tracks,
  });

  TrackState get activeTrackState => tracks[activeTrack]!;

  List<SnapshotLogEntry> get logs => activeTrackState.logs;

  factory RepoMeta.fromJson(Map<String, dynamic> json) {
    final repoId = json['repo_id'] as String;
    final projectName = json['project_name'] as String;
    final createdAt = json['created_at'] as String;
    final updatedAt = json['updated_at'] as String;
    final formatVersion = (json['format_version'] as num?)?.toInt() ?? 1;

    if (json.containsKey('tracks')) {
      final tracksJson =
          Map<String, dynamic>.from(json['tracks'] as Map<dynamic, dynamic>);

      final parsedTracks = <String, TrackState>{};

      tracksJson.forEach((key, value) {
        parsedTracks[key] = TrackState.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
      });

      final activeTrack = json['active_track']?.toString() ?? 'main';

      if (!parsedTracks.containsKey('main')) {
        parsedTracks['main'] = TrackState(logs: []);
      }

      final safeActiveTrack =
          parsedTracks.containsKey(activeTrack) ? activeTrack : 'main';

      return RepoMeta(
        repoId: repoId,
        projectName: projectName,
        createdAt: createdAt,
        updatedAt: updatedAt,
        formatVersion: max(formatVersion, 2),
        activeTrack: safeActiveTrack,
        tracks: parsedTracks,
      );
    }

    final oldLogs = ((json['logs'] as List?) ?? [])
        .map(
          (e) => SnapshotLogEntry.fromJson(
            Map<String, dynamic>.from(e as Map),
          ),
        )
        .toList();

    return RepoMeta(
      repoId: repoId,
      projectName: projectName,
      createdAt: createdAt,
      updatedAt: updatedAt,
      formatVersion: 2,
      activeTrack: 'main',
      tracks: {
        'main': TrackState(logs: oldLogs),
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'repo_id': repoId,
        'project_name': projectName,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'format_version': 2,
        'active_track': activeTrack,
        'tracks': tracks.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

  RepoMeta copyWith({
    String? updatedAt,
    String? activeTrack,
    Map<String, TrackState>? tracks,
  }) {
    return RepoMeta(
      repoId: repoId,
      projectName: projectName,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      formatVersion: 2,
      activeTrack: activeTrack ?? this.activeTrack,
      tracks: tracks ?? this.tracks,
    );
  }
}
