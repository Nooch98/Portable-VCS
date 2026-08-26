import 'dart:io';
import 'dart:math';

class RemoteRepoDotInfo {
  final Directory repoDir;
  final RepoMetaDot meta;

  RemoteRepoDotInfo({
    required this.repoDir,
    required this.meta,
  });
}

class DotfileEntry {
  final String alias;
  final String portablePath;
  final bool isDirectory;
  final String addedAt;
  final String? description;

  DotfileEntry({
    required this.alias,
    required this.portablePath,
    required this.isDirectory,
    required this.addedAt,
    this.description,
  });

  String toAbsolutePath() {
    final home = _getHomeDirectory();
    if (portablePath.startsWith('~/') || portablePath.startsWith('~\\')) {
      final relativePart = portablePath.substring(2);
      return '${home.path}${Platform.pathSeparator}$relativePart';
    }
    return portablePath;
  }

  static String toPortablePath(String absolutePath) {
    final homePath = _getHomeDirectory().path;
    
    final normalizedAbs = absolutePath.replaceAll('\\', '/');
    final normalizedHome = homePath.replaceAll('\\', '/');

    if (normalizedAbs.startsWith(normalizedHome)) {
      final relative = normalizedAbs.substring(normalizedHome.length);
      final cleanRelative = relative.startsWith('/') ? relative.substring(1) : relative;
      return '~/$cleanRelative';
    }

    return absolutePath;
  }

  static Directory _getHomeDirectory() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final userProfile = env['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return Directory(userProfile);
      }
      return Directory('C:\\Users\\${env['USERNAME'] ?? 'User'}');
    } else {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return Directory(home);
      }
      return Directory('/home/${env['USER'] ?? 'user'}');
    }
  }

  factory DotfileEntry.fromJson(Map<String, dynamic> json) {
    return DotfileEntry(
      alias: json['alias'] as String,
      portablePath: json['portable_path'] as String,
      isDirectory: (json['is_directory'] as bool?) ?? false,
      addedAt: json['added_at'] as String,
      description: json['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'portable_path': portablePath,
        'is_directory': isDirectory,
        'added_at': addedAt,
        if (description != null) 'description': description,
      };

  DotfileEntry copyWith({
    String? alias,
    String? portablePath,
    bool? isDirectory,
    String? addedAt,
    String? description,
  }) {
    return DotfileEntry(
      alias: alias ?? this.alias,
      portablePath: portablePath ?? this.portablePath,
      isDirectory: isDirectory ?? this.isDirectory,
      addedAt: addedAt ?? this.addedAt,
      description: description ?? this.description,
    );
  }
}

class SnapshotLogEntryDot {
  final String id;
  final String? parentId;
  final String message;
  final String author;
  final String timestamp;
  final int fileCount;

  SnapshotLogEntryDot({
    required this.id,
    this.parentId,
    required this.message,
    required this.author,
    required this.timestamp,
    required this.fileCount,
  });

  factory SnapshotLogEntryDot.fromJson(Map<String, dynamic> json) {
    return SnapshotLogEntryDot(
      id: json['id'] as String,
      parentId: json['parent_id'] as String?,
      message: json['message'] as String,
      author: json['author'] as String,
      timestamp: json['timestamp'] as String,
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (parentId != null) 'parent_id': parentId,
        'message': message,
        'author': author,
        'timestamp': timestamp,
        'file_count': fileCount,
      };
}

class TrackStateDot {
  final List<SnapshotLogEntryDot> logs;

  TrackStateDot({required this.logs});

  factory TrackStateDot.fromJson(Map<String, dynamic> json) {
    final logsJson = json['logs'] as List? ?? [];
    final logs = logsJson
        .map((e) => SnapshotLogEntryDot.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return TrackStateDot(logs: logs);
  }

  Map<String, dynamic> toJson() => {
        'logs': logs.map((e) => e.toJson()).toList(),
      };

  TrackStateDot copyWith({List<SnapshotLogEntryDot>? logs}) {
    return TrackStateDot(logs: logs ?? this.logs);
  }
}

class RepoMetaDot {
  final String repoId;
  final String projectName;
  final String repoType;
  final String createdAt;
  final String updatedAt;
  final int formatVersion;

  final String activeTrack;
  final Map<String, TrackStateDot> tracks;
  final Map<String, String> tags;
  
  final Map<String, DotfileEntry> entries;

  RepoMetaDot({
    required this.repoId,
    required this.projectName,
    this.repoType = 'dotfiles',
    required this.createdAt,
    required this.updatedAt,
    required this.formatVersion,
    required this.activeTrack,
    required this.tracks,
    required this.tags,
    required this.entries,
  });

  TrackStateDot get activeTrackState => tracks[activeTrack]!;

  List<SnapshotLogEntryDot> get logs => activeTrackState.logs;

  factory RepoMetaDot.fromJson(Map<String, dynamic> json) {
    final repoId = json['repo_id'] as String;
    final projectName = json['project_name'] as String;
    final createdAt = json['created_at'] as String;
    final updatedAt = json['updated_at'] as String;
    final formatVersion = (json['format_version'] as num?)?.toInt() ?? 1;

    final tags = Map<String, String>.from(json['tags'] as Map? ?? {});

    final parsedEntries = <String, DotfileEntry>{};
    if (json.containsKey('entries')) {
      final entriesJson = Map<String, dynamic>.from(json['entries'] as Map);
      entriesJson.forEach((alias, value) {
        parsedEntries[alias] = DotfileEntry.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
      });
    }

    final parsedTracks = <String, TrackStateDot>{};
    if (json.containsKey('tracks')) {
      final tracksJson = Map<String, dynamic>.from(json['tracks'] as Map);
      tracksJson.forEach((key, value) {
        parsedTracks[key] = TrackStateDot.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
      });
    }

    final activeTrack = json['active_track']?.toString() ?? 'main';
    if (!parsedTracks.containsKey('main')) {
      parsedTracks['main'] = TrackStateDot(logs: []);
    }

    final safeActiveTrack =
        parsedTracks.containsKey(activeTrack) ? activeTrack : 'main';

    return RepoMetaDot(
      repoId: repoId,
      projectName: projectName,
      repoType: json['repo_type'] as String? ?? 'dotfiles',
      createdAt: createdAt,
      updatedAt: updatedAt,
      formatVersion: max(formatVersion, 4),
      activeTrack: safeActiveTrack,
      tracks: parsedTracks,
      tags: tags,
      entries: parsedEntries,
    );
  }

  Map<String, dynamic> toJson() => {
        'repo_id': repoId,
        'project_name': projectName,
        'repo_type': repoType,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'format_version': 4,
        'active_track': activeTrack,
        'tracks': tracks.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        'tags': tags,
        'entries': entries.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

  RepoMetaDot copyWith({
    String? updatedAt,
    String? activeTrack,
    Map<String, TrackStateDot>? tracks,
    Map<String, String>? tags,
    Map<String, DotfileEntry>? entries,
  }) {
    return RepoMetaDot(
      repoId: repoId,
      projectName: projectName,
      repoType: repoType,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      formatVersion: 4,
      activeTrack: activeTrack ?? this.activeTrack,
      tracks: tracks ?? this.tracks,
      tags: tags ?? this.tags,
      entries: entries ?? this.entries,
    );
  }
}
