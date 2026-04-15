import 'package:vcs/models/snapshot_log_entry.dart';

class TrackState {
  final List<SnapshotLogEntry> logs;

  TrackState({
    required this.logs,
  });

  factory TrackState.fromJson(Map<String, dynamic> json) {
    final logsJson = (json['logs'] as List<dynamic>? ?? const []);
    return TrackState(
      logs: logsJson
          .map((e) => SnapshotLogEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'logs': logs.map((e) => e.toJson()).toList(),
    };
  }
}