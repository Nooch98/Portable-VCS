import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:vcs/vcs.dart';

class CleanupService {
  static const String _prefix = 'vcs_sandbox_';

  static Future<int> removeAllSandboxes() async {
    final tempDir = Directory.systemTemp;
    int deletedCount = 0;

    try {
      final List<FileSystemEntity> entities = await tempDir.list().toList();
      
      for (final entity in entities) {
        if (entity is Directory && entity.path.contains(_prefix)) {
          final dirName = p.basename(entity.path);
          print('🗑️ Removing: ${dirName.grey}');
          
          await entity.delete(recursive: true);
          deletedCount++;
        }
      }
    } catch (e) {
      print('❌ Error during cleanup: $e'.red);
    }
    
    return deletedCount;
  }
}
