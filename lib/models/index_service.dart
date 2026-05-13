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
}
