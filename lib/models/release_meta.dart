import 'dart:convert';

class ReleaseEntry {
  final String version;
  final String releaseId;
  final String message;
  final String snapshotPath;
  final int timestamp;

  ReleaseEntry({
    required this.version,
    required this.releaseId,
    required this.message,
    required this.snapshotPath,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'releaseId': releaseId,
    'message': message,
    'snapshotPath': snapshotPath,
    'timestamp': timestamp,
  };
}
