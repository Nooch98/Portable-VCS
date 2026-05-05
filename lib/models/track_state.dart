import 'package:vcs/models/snapshot_log_entry.dart';

class TrackState {
  final List<SnapshotLogEntry> logs;
  final String? originSnapshotId;
  final String? originTrackName;

  TrackState({
    required this.logs,
    this.originSnapshotId,
    this.originTrackName,
  });

  factory TrackState.fromJson(Map<String, dynamic> json) {
    final logsJson = (json['logs'] as List<dynamic>? ?? const []);
    return TrackState(
      logs: logsJson
          .map((e) => SnapshotLogEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      originSnapshotId: json['origin_snapshot_id'] as String?,
      originTrackName: json['origin_track_name'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'logs': logs.map((e) => e.toJson()).toList(),
      'origin_snapshot_id': originSnapshotId,
      'origin_track_name': originTrackName,
    };
  }
}
