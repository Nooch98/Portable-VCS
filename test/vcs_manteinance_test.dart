// test/vcs_maintenance_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vcs/models/decrypted_snapshot.dart';
import 'package:vcs/vcs.dart';

void main() {
  group('PortableVcs Maintenance and Support Tests', () {
    late Directory tempRoot;
    late Directory projectDir;
    late Directory fakeUsb;
    late String originalCwd;
    late PortableVcsTestable vcs;

    const testPassword = '123456';

    setUp(() async {
      originalCwd = Directory.current.path;

      tempRoot = await Directory.systemTemp.createTemp('vcs_maint_test_');

      projectDir = Directory(p.join(tempRoot.path, 'project'));
      await projectDir.create(recursive: true);

      fakeUsb = Directory(p.join(tempRoot.path, 'usb'));
      await fakeUsb.create(recursive: true);

      await File(
        p.join(fakeUsb.path, PortableVcs.driveMarkerFile),
      ).writeAsString('portable-vcs');

      await Directory(
        p.join(fakeUsb.path, PortableVcs.remoteReposDir),
      ).create(recursive: true);

      Directory.current = projectDir.path;

      vcs = PortableVcsTestable(
        fakeUsb,
        injectedPassword: testPassword,
      );

      await vcs.init();
    });

    tearDown(() async {
      Directory.current = originalCwd;
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    // =========================================================
    // 1. GITIGNORE TEST
    // =========================================================
    test('.gitignore excludes files from snapshots', () async {
      await writeProjectFile('.gitignore', 'ignored.txt\nbuild/\n');
      await writeProjectFile('tracked.txt', 'keep me');
      await writeProjectFile('ignored.txt', 'ignore me');
      await writeProjectFile('build/output.txt', 'ignore build output');

      await vcs.push('Test gitignore');

      final repoId = await readRepoId(projectDir);
      final meta = await readRemoteMeta(fakeUsb, repoId);
      final snapshotId = (meta['logs'] as List).first['id'] as String;

      final context = await vcs.loadRepoContext();
      expect(context, isNotNull);

      final snapshot = await vcs.readSnapshot(
        context!,
        snapshotId,
        password: testPassword,
      );

      expect(snapshot, isNotNull);

      final files = await decodeSnapshotFiles(snapshot!);

      expect(files.containsKey('tracked.txt'), isTrue);
      expect(files.containsKey('ignored.txt'), isFalse);
      expect(files.containsKey('build/output.txt'), isFalse);
      expect(files.containsKey('.vcs/repo.json'), isFalse);
    });

    // =========================================================
    // 2. PRUNE TEST
    // =========================================================
    test('prune --keep keeps only newest snapshots', () async {
      await writeProjectFile('file.txt', 'v1');
      await vcs.push('snapshot 1');

      await Future.delayed(const Duration(milliseconds: 5));
      await writeProjectFile('file.txt', 'v2');
      await vcs.push('snapshot 2');

      await Future.delayed(const Duration(milliseconds: 5));
      await writeProjectFile('file.txt', 'v3');
      await vcs.push('snapshot 3');

      final repoId = await readRepoId(projectDir);
      var meta = await readRemoteMeta(fakeUsb, repoId);
      expect((meta['logs'] as List).length, equals(3));

      await vcs.prune(keep: 2);

      meta = await readRemoteMeta(fakeUsb, repoId);
      final logs = meta['logs'] as List;

      expect(logs.length, equals(2));

      final snapshotsDir = Directory(
        p.join(fakeUsb.path, PortableVcs.remoteReposDir, repoId, 'snapshots'),
      );

      final snapshotFiles = snapshotsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.vcs'))
          .toList();

      expect(snapshotFiles.length, equals(2));
    });

    // =========================================================
    // 3. BIND TEST
    // =========================================================
    test('bind links current folder to an existing remote repo', () async {
      await writeProjectFile('lib/app.txt', 'hello bind');
      await vcs.push('initial');

      final repoId = await readRepoId(projectDir);

      final secondMachineDir = Directory(p.join(tempRoot.path, 'existing_folder'));
      await secondMachineDir.create(recursive: true);

      // recreate same contents manually
      final oldCwd = Directory.current.path;
      Directory.current = secondMachineDir.path;
      await writeProjectFile('lib/app.txt', 'hello bind');

      final bindVcs = PortableVcsTestable(
        fakeUsb,
        injectedPassword: testPassword,
      );

      await bindVcs.bindRepo(repoId: repoId);

      final localRepoFile = File(
        p.join(
          secondMachineDir.path,
          PortableVcs.localMetaDirName,
          PortableVcs.localRepoFileName,
        ),
      );

      expect(localRepoFile.existsSync(), isTrue);

      final localJson =
          jsonDecode(await localRepoFile.readAsString()) as Map<String, dynamic>;

      expect(localJson['repo_id'], equals(repoId));

      Directory.current = oldCwd;
    });

    // =========================================================
    // 4. VERIFY TEST
    // =========================================================
    test('verify succeeds for valid snapshot and fails for wrong password', () async {
      await writeProjectFile('verify.txt', 'content');
      await vcs.push('verify snapshot');

      final repoId = await readRepoId(projectDir);
      final meta = await readRemoteMeta(fakeUsb, repoId);
      final snapshotId = (meta['logs'] as List).first['id'] as String;

      final okOutput = await capturePrints(() async {
        await vcs.verify(snapshotId);
      });

      expect(
        okOutput.any((line) => line.contains('valid and decryptable')),
        isTrue,
      );

      final wrongPassVcs = PortableVcsTestable(
        fakeUsb,
        injectedPassword: 'wrong-password',
      );

      Directory.current = projectDir.path;

      final badOutput = await capturePrints(() async {
        await wrongPassVcs.verify(snapshotId);
      });

      expect(
        badOutput.any((line) => line.contains('Wrong password or tampered snapshot')),
        isTrue,
      );
    });

    // =========================================================
    // 5. DOCTOR TEST
    // =========================================================
    test('doctor reports healthy initialized repository', () async {
      await writeProjectFile('doctor.txt', 'ok');
      await vcs.push('doctor snapshot');

      final output = await capturePrints(() async {
        await vcs.doctor();
      });

      expect(output.any((l) => l.contains('Local repository metadata exists')), isTrue);
      expect(output.any((l) => l.contains('Prepared USB drive available')), isTrue);
      expect(output.any((l) => l.contains('Remote repository exists on USB')), isTrue);
      expect(output.any((l) => l.contains('Repository has snapshots')), isTrue);
    });

    // =========================================================
    // 6. STATS TEST
    // =========================================================
    test('stats reports repository numbers', () async {
      await writeProjectFile('stats.txt', 'v1');
      await vcs.push('stats 1');

      await writeProjectFile('stats.txt', 'v2');
      await vcs.push('stats 2');

      final output = await capturePrints(() async {
        await vcs.stats();
      });

      expect(output.any((l) => l.contains('Project: project')), isTrue);
      expect(output.any((l) => l.contains('Snapshot count: 2')), isTrue);
      expect(output.any((l) => l.contains('Total snapshot size:')), isTrue);
      expect(output.any((l) => l.contains('Newest snapshot:')), isTrue);
      expect(output.any((l) => l.contains('Oldest snapshot:')), isTrue);
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

  // IMPORTANT:
  // This assumes you extracted confirmations to a public/protected method.
  @override
  bool confirmAction(String message) {
    return true;
  }
}

//
// =============================================================
// HELPERS
// =============================================================
//

Future<void> writeProjectFile(String relativePath, String content) async {
  final file = File(p.join(Directory.current.path, relativePath));
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
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

Future<Map<String, dynamic>> readRemoteMeta(Directory fakeUsb, String repoId) async {
  final metaFile = File(
    p.join(
      fakeUsb.path,
      PortableVcs.remoteReposDir,
      repoId,
      PortableVcs.remoteMetaFileName,
    ),
  );

  return jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
}

Future<Map<String, Uint8List>> decodeSnapshotFiles(DecryptedSnapshot snapshot) async {
  final archive = ZipDecoder().decodeBytes(snapshot.zipBytes, verify: true);
  final files = <String, Uint8List>{};

  for (final file in archive) {
    if (!file.isFile) continue;
    final content = file.content;
    if (content is List<int>) {
      files[file.name.replaceAll('\\', '/')] = Uint8List.fromList(content);
    }
  }

  return files;
}

Future<List<String>> capturePrints(Future<void> Function() action) async {
  final lines = <String>[];

  await runZoned(
    () async {
      await action();
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, message) {
        lines.add(message);
      },
    ),
  );

  return lines;
}
