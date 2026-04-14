// test/vcs_init_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'package:vcs/vcs.dart';

void main() {
  group('PortableVcs - init()', () {
    late Directory tempRoot;
    late Directory projectDir;
    late Directory fakeUsb;
    late String originalCwd;

    setUp(() async {
      originalCwd = Directory.current.path;

      tempRoot = await Directory.systemTemp.createTemp('vcs_test_');

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
    });

    tearDown(() async {
      Directory.current = originalCwd;

      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('creates local .vcs/repo.json and remote repo structure', () async {
      final vcs = PortableVcsTestable(fakeUsb);

      await vcs.init();

      final localMetaDir = Directory(
        p.join(projectDir.path, PortableVcs.localMetaDirName),
      );

      final localRepoFile = File(
        p.join(
          localMetaDir.path,
          PortableVcs.localRepoFileName,
        ),
      );

      expect(localMetaDir.existsSync(), isTrue);
      expect(localRepoFile.existsSync(), isTrue);

      final localJson =
          jsonDecode(await localRepoFile.readAsString()) as Map<String, dynamic>;

      expect(localJson.containsKey('repo_id'), isTrue);
      expect(localJson['project_name'], equals('project'));
      expect(localJson['format_version'], equals(1));

      final repoId = localJson['repo_id'] as String;
      expect(repoId.isNotEmpty, isTrue);

      final remoteRepoDir = Directory(
        p.join(
          fakeUsb.path,
          PortableVcs.remoteReposDir,
          repoId,
        ),
      );

      final remoteMetaFile = File(
        p.join(
          remoteRepoDir.path,
          PortableVcs.remoteMetaFileName,
        ),
      );

      final snapshotsDir = Directory(
        p.join(remoteRepoDir.path, 'snapshots'),
      );

      expect(remoteRepoDir.existsSync(), isTrue);
      expect(remoteMetaFile.existsSync(), isTrue);
      expect(snapshotsDir.existsSync(), isTrue);

      final remoteJson =
          jsonDecode(await remoteMetaFile.readAsString()) as Map<String, dynamic>;

      expect(remoteJson['repo_id'], equals(repoId));
      expect(remoteJson['project_name'], equals('project'));
      expect(remoteJson['logs'], isEmpty);
    });

    test('init should not overwrite existing initialized repo', () async {
      final vcs = PortableVcsTestable(fakeUsb);

      await vcs.init();

      final firstRepoFile = File(
        p.join(
          projectDir.path,
          PortableVcs.localMetaDirName,
          PortableVcs.localRepoFileName,
        ),
      );

      final firstContent = await firstRepoFile.readAsString();

      await vcs.init();

      final secondContent = await firstRepoFile.readAsString();

      expect(secondContent, equals(firstContent));
    });
  });
}

class PortableVcsTestable extends PortableVcs {
  final Directory fakeUsb;

  PortableVcsTestable(this.fakeUsb);

  @override
  Future<Directory?> findUsbDrive() async {
    return fakeUsb;
  }
}