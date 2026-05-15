import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class IndexService {
  static Future<void> saveSnapshotIndex({
    required Directory remoteRepoDir,
    required String snapshotId,
    required Map<String, String> fileMap,
  }) async {
    final indexDir = Directory(p.join(remoteRepoDir.path, 'index'));
    if (!indexDir.existsSync()) {
      await indexDir.create(recursive: true);
    }

    final indexFile = File(p.join(indexDir.path, '$snapshotId.json'));
    
    final data = {
      'snapshot_id': snapshotId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'files_count': fileMap.length,
      'file_map': fileMap,
    };

    await indexFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }

  static Future<Map<String, String>?> loadSnapshotIndex(
    Directory remoteRepoDir, 
    String snapshotId
  ) async {
    final indexFile = File(p.join(remoteRepoDir.path, 'index', '$snapshotId.json'));
    if (!indexFile.existsSync()) return null;

    try {
      final content = await indexFile.readAsString();
      final data = jsonDecode(content);
      return Map<String, String>.from(data['file_map']);
    } catch (e) {
      print('⚠️ Error reading index for $snapshotId: $e');
      return null;
    }
  }

  static Future<void> deleteSnapshotIndex({
    required Directory remoteRepoDir,
    required String snapshotId,
  }) async {
    try {
      final indexFile = File(p.join(remoteRepoDir.path, 'index', '$snapshotId.json'));
      if (indexFile.existsSync()) {
        await indexFile.delete();
      }
    } catch (e) {
      print('⚠️ Non-critical: Could not delete index for $snapshotId: $e');
    }
  }

  static Future<String> generateDeltaReport({
    required Directory remoteRepoDir,
    required String currentId,
    String? previousId,
    String? extensionFilter,
  }) async {
    final currentMap = await loadSnapshotIndex(remoteRepoDir, currentId);
    if (currentMap == null) return "[[ RED: ERROR ]] Index file not found for snapshot: $currentId";

    final sb = StringBuffer();
    sb.writeln("# Snapshot Index Viewer");
    sb.writeln("Snapshot ID: [[ CYAN: $currentId ]]");
    if (extensionFilter != null) {
      sb.writeln("Filter: [[ YELLOW: *$extensionFilter ]]");
    }
    
    final filteredMap = extensionFilter == null 
        ? currentMap 
        : Map.fromEntries(currentMap.entries.where((e) => e.key.toLowerCase().endsWith(extensionFilter.toLowerCase())));

    sb.writeln("Files found: **${filteredMap.length}** (Total in snapshot: ${currentMap.length})");
    sb.writeln("---");

    if (filteredMap.isEmpty) {
      sb.writeln("\n[[ grey: No files found matching the criteria. ]]");
      return sb.toString();
    }

    Map<String, List<String>> groupedFiles = {};
    for (var path in filteredMap.keys) {
      final normalizedPath = p.normalize(path);
      final dir = p.dirname(normalizedPath);
      groupedFiles.putIfAbsent(dir == '.' ? '/' : dir, () => []).add(path);
    }

    final sortedDirs = groupedFiles.keys.toList()..sort();
    for (var dir in sortedDirs) {
      sb.writeln("\n### [[ YELLOW: $dir ]]");
      final pathsInDir = groupedFiles[dir]!..sort();
      for (var originalPath in pathsInDir) {
        final fileName = p.basename(originalPath);
        final fullHash = filteredMap[originalPath];
        final shortHash = (fullHash != null && fullHash.length > 8) ? fullHash.substring(0, 8) : fullHash;
        sb.writeln("  • $fileName [[ grey: ($shortHash) ]]");
      }
    }

    return sb.toString();
  }
}
