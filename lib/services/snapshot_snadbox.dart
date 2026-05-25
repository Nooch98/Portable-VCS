import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:vcs/models/index_service.dart';
import 'package:vcs/models/decrypted_snapshot.dart';

class SnapshotSandbox {
  final Directory remoteRepoDir;

  SnapshotSandbox(this.remoteRepoDir);

  Future<Directory> provision(String snapshotId, DecryptedSnapshot snapshot) async {
    final tempDir = await Directory.systemTemp.createTemp('vcs_sandbox_${snapshotId}_');

    final fileMap = await IndexService.loadSnapshotIndex(remoteRepoDir, snapshotId);
    if (fileMap == null) {
      throw Exception('No se pudo encontrar el índice para el snapshot: $snapshotId');
    }

    final archive = ZipDecoder().decodeBytes(snapshot.zipBytes, verify: true);

    for (final file in archive) {
      if (!file.isFile) continue;
      final relativePath = file.name.replaceAll('\\', '/');
      final targetFile = File(p.join(tempDir.path, relativePath));
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsBytes(Uint8List.fromList(file.content), flush: true);
    }

    return tempDir;
  }
}
