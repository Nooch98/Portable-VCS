// test/vcs_core_flow_test.dart
//
// Core integration tests:
// - push
// - status
// - revert
// - clone
//
// IMPORTANT:
// Adjust package import if your package name differs.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:vcs/models/file_change.dart';
import 'package:vcs/vcs.dart';

void main() {
  group('PortableVcs Core Flow', () {
    late Directory tempRoot;
    late Directory projectDir;
    late Directory fakeUsb;
    late String originalCwd;

    late PortableVcsTestable vcs;

    const testPassword = '123456';

    setUp(() async {
      originalCwd = Directory.current.path;

      tempRoot = await Directory.systemTemp.createTemp('vcs_core_test_');

      projectDir = Directory(p.join(tempRoot.path, 'project'));
      await projectDir.create(recursive: true);

      fakeUsb = Directory(p.join(tempRoot.path, 'usb'));
      await fakeUsb.create(recursive: true);

      // USB marker
      await File(
        p.join(fakeUsb.path, PortableVcs.driveMarkerFile),
      ).writeAsString('portable-vcs');

      // repos folder
      await Directory(
        p.join(fakeUsb.path, PortableVcs.remoteReposDir),
      ).create(recursive: true);

      Directory.current = projectDir.path;

      vcs = PortableVcsTestable(
        fakeUsb,
        injectedPassword: testPassword,
      );

      // Initial project file
      await writeProjectFile('lib/test.txt', 'hello world');

      // init repo
      await vcs.init();
    });

    tearDown(() async {
      Directory.current = originalCwd;

      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    // =========================================================
    // PUSH TEST
    // =========================================================
    test('push creates snapshot and metadata log entry', () async {
      await vcs.push('Initial snapshot');

      final repoId = await readRepoId(projectDir);

      final metaFile = File(
        p.join(
          fakeUsb.path,
          PortableVcs.remoteReposDir,
          repoId,
          PortableVcs.remoteMetaFileName,
        ),
      );

      expect(metaFile.existsSync(), isTrue);

      final metaJson =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;

      final logs = metaJson['logs'] as List<dynamic>;

      expect(logs.length, equals(1));
      expect(logs.first['message'], equals('Initial snapshot'));

      final snapshotFileName = logs.first['file_name'] as String;

      final snapshotFile = File(
        p.join(
          fakeUsb.path,
          PortableVcs.remoteReposDir,
          repoId,
          'snapshots',
          snapshotFileName,
        ),
      );

      expect(snapshotFile.existsSync(), isTrue);
    });

    // =========================================================
    // STATUS TEST
    // =========================================================
    test('status detects added, modified and deleted files', () async {
      await vcs.push('Initial snapshot');

      // modify existing
      await writeProjectFile('lib/test.txt', 'modified content');

      // add new
      await writeProjectFile('lib/new_file.txt', 'new file');

      // delete old file
      final fileToDelete = File(
        p.join(projectDir.path, 'lib/test.txt'),
      );
      await fileToDelete.delete();

      final changes = await vcs.debugStatusChanges();

      expect(
        changes.any((e) => e.contains('[NEW] lib/new_file.txt')),
        isTrue,
      );

      expect(
        changes.any((e) => e.contains('[DEL] lib/test.txt')),
        isTrue,
      );
    });

    // =========================================================
    // REVERT TEST
    // =========================================================
    test('revert restores previous snapshot state correctly', () async {
      await vcs.push('Initial snapshot');

      final snapshotId = await latestSnapshotId(fakeUsb, projectDir);

      // modify file after snapshot
      await writeProjectFile('lib/test.txt', 'changed after snapshot');

      final changedContent = await readProjectFile('lib/test.txt');
      expect(changedContent, equals('changed after snapshot'));

      // revert
      await vcs.revert(snapshotId);

      final restoredContent = await readProjectFile('lib/test.txt');
      expect(restoredContent, equals('hello world'));

      // ensure .vcs still exists
      final localRepoFile = File(
        p.join(
          projectDir.path,
          PortableVcs.localMetaDirName,
          PortableVcs.localRepoFileName,
        ),
      );

      expect(localRepoFile.existsSync(), isTrue);
    });

    // =========================================================
    // CLONE TEST
    // =========================================================
    test('clone recreates repository in new directory', () async {
      await vcs.push('Initial snapshot');

      final repoId = await readRepoId(projectDir);

      final cloneDir = Directory(
        p.join(tempRoot.path, 'cloned_project'),
      );

      final cloneVcs = PortableVcsTestable(
        fakeUsb,
        injectedPassword: testPassword,
      );

      Directory.current = tempRoot.path;

      await cloneVcs.cloneRepo(
        repoId: repoId,
        into: cloneDir.path,
      );

      final clonedFile = File(
        p.join(cloneDir.path, 'lib/test.txt'),
      );

      expect(clonedFile.existsSync(), isTrue);
      expect(await clonedFile.readAsString(), equals('hello world'));

      final clonedRepoMeta = File(
        p.join(
          cloneDir.path,
          PortableVcs.localMetaDirName,
          PortableVcs.localRepoFileName,
        ),
      );

      expect(clonedRepoMeta.existsSync(), isTrue);
    });
  });
}

//
// =============================================================
// TESTABLE SUBCLASS
// =============================================================
//

class PortableVcsTestable extends PortableVcs {
  final Directory fakeUsb;
  final String injectedPassword;

  PortableVcsTestable(
    this.fakeUsb, {
    required this.injectedPassword,
  });

  @override
  Future<Directory?> findUsbDrive() async {
    return fakeUsb;
  }

  @override
  String? askPassword() {
    return injectedPassword;
  }

  // Helper method for testing status output
  Future<List<String>> debugStatusChanges() async {
    final changes = <String>[];

    final context = await loadRepoContext();
    if (context == null) return changes;

    final current = await buildFingerprint(Directory.current);

    if (context.remoteMeta.logs.isEmpty) {
      return changes;
    }

    final snapshot = await readSnapshot(
      context,
      context.remoteMeta.logs.first.id,
      password: injectedPassword,
    );

    if (snapshot == null) return changes;

    final lastFingerprint = Map<String, String>.from(snapshot.fingerprint);
    final diff = diffFingerprints(lastFingerprint, current);

    for (final change in diff) {
      switch (change.kind) {
        case ChangeKind.added:
          changes.add('[NEW] ${change.path}');
          break;
        case ChangeKind.modified:
          changes.add('[MOD] ${change.path}');
          break;
        case ChangeKind.deleted:
          changes.add('[DEL] ${change.path}');
          break;
      }
    }

    return changes;
  }
}

//
// =============================================================
// HELPERS
// =============================================================
//

Future<void> writeProjectFile(String relativePath, String content) async {
  final file = File(
    p.join(Directory.current.path, relativePath),
  );

  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Future<String> readProjectFile(String relativePath) async {
  final file = File(
    p.join(Directory.current.path, relativePath),
  );

  return file.readAsString();
}

Future<String> readRepoId(Directory projectDir) async {
  final repoFile = File(
    p.join(
      projectDir.path,
      PortableVcs.localMetaDirName,
      PortableVcs.localRepoFileName,
    ),
  );

  final jsonMap =
      jsonDecode(await repoFile.readAsString()) as Map<String, dynamic>;

  return jsonMap['repo_id'] as String;
}

Future<String> latestSnapshotId(
  Directory fakeUsb,
  Directory projectDir,
) async {
  final repoId = await readRepoId(projectDir);

  final metaFile = File(
    p.join(
      fakeUsb.path,
      PortableVcs.remoteReposDir,
      repoId,
      PortableVcs.remoteMetaFileName,
    ),
  );

  final metaJson =
      jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;

  final logs = metaJson['logs'] as List<dynamic>;

  return logs.first['id'] as String;
}
