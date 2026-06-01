import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:vcs/vcs.dart'; 

class CleanupService {
  static const List<String> _prefixes = [
    'vcs_sandbox_',
    'tmp_restore_',
    'backup_before_restore_',
    'backup_before_git_publish'
  ];

  static Future<int> removeAllSandboxes({List<String>? extraPaths}) async {
    final List<Directory> targets = [];
    final directoriesToScan = [Directory.systemTemp];

    if (extraPaths != null) {
      for (final path in extraPaths) {
        final dir = Directory(path);
        if (dir.existsSync()) {
          directoriesToScan.add(dir);
        } else {
          print('⚠️ Debug: Path provided but not found: $path'.yellow);
        }
      }
    }

    for (final dir in directoriesToScan) {
      if (!dir.existsSync()) continue;
      
      final entities = await dir.list(recursive: false).toList(); 
      
      for (final entity in entities) {
        if (entity is Directory) {
          final dirName = p.basename(entity.path);
          final display = dirName.length > 40 ? '${dirName.substring(0, 37)}...' : dirName;          
          stdout.write('\r🔍 Scanning: $display\x1b[K');
          
          final matches = _prefixes.any((prefix) => dirName.startsWith(prefix));
          if (matches) {
            targets.add(entity);
          }
        }
      }
    }
    stdout.write('\n');

    if (targets.isEmpty) {
      print('✨ No temporary cleanup items found.');
      return 0;
    }

    print('🔍 The following items are queued for deletion:');
    for (final target in targets) {
      print('   - ${target.path.grey}');
    }

    stdout.write('\n⚠️ Proceed with deletion of these ${targets.length} items? (y/N): ');
    final input = stdin.readLineSync()?.trim().toLowerCase();

    if (input != 'y') {
      print('🚫 Cleanup aborted.');
      return 0;
    }

    int deletedCount = 0;
    for (final target in targets) {
      try {
        await target.delete(recursive: true);
        print('🗑️ Deleted: ${p.basename(target.path)}'.green);
        deletedCount++;
      } catch (e) {
        print('❌ Failed to delete ${p.basename(target.path)}: $e'.red);
      }
    }

    print('✅ Cleanup complete. $deletedCount items removed.'.green);
    return deletedCount;
  }
}
