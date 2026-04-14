import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' as crypto_alg;
import 'package:path/path.dart' as p;
import 'package:vcs/models/decrypted_snapshot.dart';
import 'package:vcs/models/file_change.dart';
import 'package:vcs/models/ignore_rule.dart';
import 'package:vcs/models/repo_context.dart';
import 'package:vcs/models/repo_meta.dart';
import 'package:vcs/models/snapshot_log_entry.dart';

class PortableVcs {
  static const String driveMarkerFile = '.vcs_drive';
  static const String localMetaDirName = '.vcs';
  static const String localRepoFileName = 'repo.json';
  static const String remoteReposDir = 'repos';
  static const String remoteMetaFileName = 'meta.json';
  static const String lockFileName = '.lock';

  final List<String> internalIgnoredNames = const [
    '.git',
    '.dart_tool',
    'build',
    'node_modules',
    '.idea',
    '.vscode',
    '.DS_Store',
    localMetaDirName,
  ];

  Directory get _cwd => Directory.current;
  Directory get _localMetaDir => Directory(p.join(_cwd.path, localMetaDirName));
  File get _localRepoFile => File(p.join(_localMetaDir.path, localRepoFileName));
  File get _gitignoreFile => File(p.join(_cwd.path, '.gitignore'));

  void showHelp() {
    print('\n🚀 ${'PORTABLE SNAPSHOT VAULT'.cyan}');
    print('${'Offline encrypted snapshot tool for Git-compatible local workflows.'.yellow}\n');

    print('${"Usage".cyan}');
    print('  vcs <command> [arguments]\n');

    print('${"Repository setup".cyan}');
    print('  ${'setup'.green.padRight(28)} Prepare a USB drive or external storage for VCS use.');
    print('  ${'init'.green.padRight(28)} Initialize the current project and link it to remote storage.');
    print('  ${'list'.green.padRight(28)} List repositories available on the connected USB/storage.');
    print('  ${'clone [repo_id] [--into dir]'.green.padRight(28)} Clone a repository from USB into a local folder.');
    print('  ${'bind [repo_id]'.green.padRight(28)} Bind the current folder to an existing remote repository.');

    print('\n${"Snapshot workflow".cyan}');
    print('  ${'push "message" [-a author]'.green.padRight(28)} Create a new encrypted snapshot of the current project.');
    print('  ${'pull'.green.padRight(28)} Restore the latest snapshot into the current project.');
    print('  ${'revert <snapshot_id>'.green.padRight(28)} Restore a specific snapshot into the current project.');
    print('  ${'restore <snapshot_id> --to dir'.green.padRight(28)} Restore a specific snapshot into another folder.');

    print('\n${"Inspection".cyan}');
    print('  ${'status'.green.padRight(28)} Compare current files against the latest snapshot.');
    print('  ${'diff'.green.padRight(28)} Compare working tree vs latest snapshot.');
    print('  ${'diff <id>'.green.padRight(28)} Compare a specific snapshot vs working tree.');
    print('  ${'diff <id1> <id2>'.green.padRight(28)} Compare two snapshots.');
    print('  ${'log'.green.padRight(28)} Show full snapshot history.');
    print('  ${'show <snapshot_id>'.green.padRight(28)} Show detailed information about one snapshot.');
    print('  ${'verify <snapshot_id>'.green.padRight(28)} Verify that a snapshot can be decrypted and read.');

    print('\n${"Git integration".cyan}');
    print('  ${'git-prepare [id] --branch main'.green.padRight(28)} Prepare current Git repo from a snapshot.');
    print('  ${'publish [id] --branch main'.green.padRight(28)} Commit and push snapshot to Git safely.');
    print('  ${'publish [id] --branch main --dry-run'.green.padRight(28)} Show what would happen without changing anything.');

    print('\n${"Maintenance".cyan}');
    print('  ${'doctor'.green.padRight(28)} Run repository diagnostics and health checks.');
    print('  ${'stats'.green.padRight(28)} Show repository size, snapshot count, and storage statistics.');
    print('  ${'prune --keep N'.green.padRight(28)} Keep only the newest N snapshots.');
    print('  ${'prune --older-than D'.green.padRight(28)} Delete snapshots older than D days.');
    print('  ${'clear-history'.green.padRight(28)} Delete all snapshots for this repo, but keep repo structure.');
    print('  ${'purge'.green.padRight(28)} Completely delete this repository from USB/storage.');

    print('\n${"General".cyan}');
    print('  ${'help'.green.padRight(28)} Show this help message.');

    print('\n${"Examples".cyan}');
    print('  ${'vcs setup'.green}');
    print('  ${'vcs init'.green}');
    print('  ${'vcs push "offline checkpoint" -a Nooch98'.green}');
    print('  ${'vcs log'.green}');
    print('  ${'vcs diff'.green}');
    print('  ${'vcs revert 1776137235094'.green}');
    print('  ${'vcs clone'.green}');
    print('  ${'vcs prune --keep 10'.green}');

    print('\n${"Notes".cyan}');
    print('  - Portable VCS is a local offline complement to Git, not a replacement.');
    print('  - The tool reads ${'.gitignore'.green} and always ignores internal ${'.vcs/'.green} metadata.');
    print('  - Snapshots are encrypted and require the correct password to inspect or restore.\n');
  }

  Future<void> setupDrive() async {
    final candidates = await _listCandidateDrives();
    if (candidates.isEmpty) {
      print('❌ No candidate drives found.');
      return;
    }

    print('Detected drives:');
    for (var i = 0; i < candidates.length; i++) {
      print('[$i] ${candidates[i].path}');
    }

    stdout.write('Select index to provision: ');
    final raw = stdin.readLineSync()?.trim() ?? '';
    final index = int.tryParse(raw);
    if (index == null || index < 0 || index >= candidates.length) {
      print('❌ Invalid index.');
      return;
    }

    final selected = candidates[index];
    await File(p.join(selected.path, driveMarkerFile)).writeAsString(
      'portable-vcs\n',
      flush: true,
    );
    await Directory(p.join(selected.path, remoteReposDir)).create(recursive: true);

    print('✅ Drive prepared at ${selected.path}');
  }

  Future<void> init() async {
    final usb = await findUsbDrive();
    if (usb == null) {
      print('❌ No prepared USB drive found. Run setup first.');
      return;
    }

    if (_localRepoFile.existsSync()) {
      print('⚠️ This project is already initialized.');
      return;
    }

    await _localMetaDir.create(recursive: true);

    final repoId = _randomId(24);
    final projectName = p.basename(_cwd.path);
    final createdAt = DateTime.now().toUtc().toIso8601String();

    final localRepoMeta = {
      'repo_id': repoId,
      'project_name': projectName,
      'created_at': createdAt,
      'format_version': 1,
    };

    await _atomicWriteString(
      _localRepoFile,
      const JsonEncoder.withIndent('  ').convert(localRepoMeta),
    );

    final remoteRepoDir = Directory(p.join(usb.path, remoteReposDir, repoId));
    await remoteRepoDir.create(recursive: true);
    await Directory(p.join(remoteRepoDir.path, 'snapshots')).create(recursive: true);

    final remoteMeta = {
      'repo_id': repoId,
      'project_name': projectName,
      'created_at': createdAt,
      'updated_at': createdAt,
      'format_version': 1,
      'logs': <Map<String, dynamic>>[],
    };

    await _atomicWriteString(
      File(p.join(remoteRepoDir.path, remoteMetaFileName)),
      const JsonEncoder.withIndent('  ').convert(remoteMeta),
    );

    print("✅ Project '$projectName' initialized with repo_id=$repoId");
  }

  Future<void> listRepos() async {
    final usb = await findUsbDrive();
    if (usb == null) {
      print('❌ No prepared USB drive found.'.red);
      return;
    }

    final repos = await _loadRemoteRepos(usb);
    if (repos.isEmpty) {
      print('ℹ️ No repositories found on USB.'.yellow);
      return;
    }

    print('\n📦 ${"Available repositories:".cyan}\n');

    for (var i = 0; i < repos.length; i++) {
      final repo = repos[i];
      final snapshotCount = repo.meta.logs.length;
      final updatedAt = _formatDateForList(repo.meta.updatedAt);

      print('[${i.toString().padLeft(2, '0')}] ${repo.meta.projectName.green}');
      print('     ${"Repo ID:".yellow}   ${repo.meta.repoId}');
      print('     ${"Snapshots:".yellow} $snapshotCount');
      print('     ${"Updated:".yellow}   $updatedAt');
      print('');
    }
  }

  String _formatDateForList(String isoDate) {
    final dt = DateTime.tryParse(isoDate);
    if (dt == null) return isoDate;

    final local = dt.toLocal();

    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');

    return '$y-$m-$d $h:$min';
  }

  Future<void> cloneRepo({String? repoId, String? into}) async {
    final usb = await findUsbDrive();
    if (usb == null) {
      print('❌ No prepared USB drive found.');
      return;
    }

    final repos = await _loadRemoteRepos(usb);
    if (repos.isEmpty) {
      print('ℹ️ No repositories found on USB.');
      return;
    }

    RemoteRepoInfo? selected = _selectRemoteRepo(repos, repoId);
    if (selected == null) return;

    if (selected.meta.logs.isEmpty) {
      print('❌ Repository has no snapshots. Nothing to clone.');
      return;
    }

    final targetPath = into != null && into.trim().isNotEmpty
        ? p.normalize(p.isAbsolute(into) ? into : p.join(_cwd.path, into))
        : p.join(_cwd.path, selected.meta.projectName);

    final targetDir = Directory(targetPath);

    if (targetDir.existsSync()) {
      final children = targetDir.listSync();
      if (children.isNotEmpty) {
        print('❌ Target folder already exists and is not empty: $targetPath');
        return;
      }
    } else {
      await targetDir.create(recursive: true);
    }

    final localRepoFile = File(p.join(targetDir.path, localMetaDirName, localRepoFileName));
    if (localRepoFile.existsSync()) {
      print('❌ Target folder already contains a local VCS repo.');
      return;
    }

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshotByMeta(
      remoteRepoDir: selected.repoDir,
      remoteMeta: selected.meta,
      snapshotId: selected.meta.logs.first.id,
      password: password,
    );
    if (snapshot == null) return;

    try {
      await _extractZipToDirectory(snapshot.zipBytes, targetDir);

      final localMetaDir = Directory(p.join(targetDir.path, localMetaDirName));
      await localMetaDir.create(recursive: true);

      final localRepoMeta = {
        'repo_id': selected.meta.repoId,
        'project_name': selected.meta.projectName,
        'created_at': selected.meta.createdAt,
        'format_version': selected.meta.formatVersion,
      };

      await _atomicWriteString(
        File(p.join(localMetaDir.path, localRepoFileName)),
        const JsonEncoder.withIndent('  ').convert(localRepoMeta),
      );

      print('✅ Repository cloned into: ${targetDir.path}');
      print('✅ Linked to repo_id=${selected.meta.repoId}');
    } catch (e) {
      print('❌ Clone failed: $e');
    }
  }

  Future<void> bindRepo({String? repoId}) async {
    if (_localRepoFile.existsSync()) {
      print('❌ This folder is already bound to a VCS repository.');
      return;
    }

    final usb = await findUsbDrive();
    if (usb == null) {
      print('❌ No prepared USB drive found.');
      return;
    }

    final repos = await _loadRemoteRepos(usb);
    if (repos.isEmpty) {
      print('ℹ️ No repositories found on USB.');
      return;
    }

    final selected = _selectRemoteRepo(repos, repoId);
    if (selected == null) return;

    if (selected.meta.logs.isEmpty) {
      print('❌ Selected repository has no snapshots.');
      return;
    }

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshotByMeta(
      remoteRepoDir: selected.repoDir,
      remoteMeta: selected.meta,
      snapshotId: selected.meta.logs.first.id,
      password: password,
    );
    if (snapshot == null) return;

    final currentFingerprint = await buildFingerprint(_cwd);
    final remoteFingerprint = Map<String, String>.from(snapshot.fingerprint);
    final changes = diffFingerprints(remoteFingerprint, currentFingerprint);

    if (changes.isNotEmpty) {
      print('⚠️ Current folder does not match the latest remote snapshot.');
      print('Differences found:');
      for (final c in changes.take(20)) {
        switch (c.kind) {
          case ChangeKind.added:
            print('  ${'[NEW]'.green} ${c.path}');
            break;
          case ChangeKind.modified:
            print('  ${'[MOD]'.yellow} ${c.path}');
            break;
          case ChangeKind.deleted:
            print('  ${'[DEL]'.red} ${c.path}');
            break;
        }
      }
      if (changes.length > 20) {
        print('  ... and ${changes.length - 20} more');
      }
      stdout.write('Bind anyway? (y/N): ');
      if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') {
        print('Cancelled.');
        return;
      }
    }

    await _localMetaDir.create(recursive: true);

    final localRepoMeta = {
      'repo_id': selected.meta.repoId,
      'project_name': selected.meta.projectName,
      'created_at': selected.meta.createdAt,
      'format_version': selected.meta.formatVersion,
    };

    await _atomicWriteString(
      _localRepoFile,
      const JsonEncoder.withIndent('  ').convert(localRepoMeta),
    );

    print('✅ Current folder is now bound to repo_id=${selected.meta.repoId}');
  }

  Future<void> status() async {
    final context = await loadRepoContext();
    if (context == null) return;

    final current = await buildFingerprint(_cwd);
    final logs = context.remoteMeta.logs;

    if (logs.isEmpty) {
      if (current.isEmpty) {
        print('✨ Empty project.');
        return;
      }
      print('📝 Files not yet saved:');
      for (final path in current.keys.toList()..sort()) {
        print('  ${'[NEW]'.green} $path');
      }
      return;
    }

    final password = askPassword();
    if (password == null) return;

    final lastEntry = logs.first;
    final snapshot = await readSnapshot(
      context,
      lastEntry.id,
      password: password,
    );
    if (snapshot == null) return;

    final lastFingerprint = Map<String, String>.from(snapshot.fingerprint);
    final changes = diffFingerprints(lastFingerprint, current);

    if (changes.isEmpty) {
      print('✨ Clean.');
      return;
    }

    for (final change in changes) {
      switch (change.kind) {
        case ChangeKind.added:
          print('  ${'[NEW]'.green} ${change.path}');
          break;
        case ChangeKind.modified:
          print('  ${'[MOD]'.yellow} ${change.path}');
          break;
        case ChangeKind.deleted:
          print('  ${'[DEL]'.red} ${change.path}');
          break;
      }
    }
  }

  Future<void> diff(List<String> args) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final password = askPassword();
    if (password == null) return;

    late final Map<String, Uint8List> leftFiles;
    late final Map<String, Uint8List> rightFiles;
    late final String leftLabel;
    late final String rightLabel;

    if (args.isEmpty) {
      if (context.remoteMeta.logs.isEmpty) {
        print('ℹ️ No snapshots available.'.yellow);
        return;
      }

      final latest = context.remoteMeta.logs.first;
      final snapshot = await readSnapshot(context, latest.id, password: password);
      if (snapshot == null) return;

      leftFiles = await _decodeSnapshotFiles(snapshot);
      rightFiles = await _readCurrentProjectFiles();
      leftLabel = 'snapshot:${latest.id}';
      rightLabel = 'working-tree';
    } else if (args.length == 1) {
      final snapshot = await readSnapshot(context, args[0], password: password);
      if (snapshot == null) return;

      leftFiles = await _decodeSnapshotFiles(snapshot);
      rightFiles = await _readCurrentProjectFiles();
      leftLabel = 'snapshot:${args[0]}';
      rightLabel = 'working-tree';
    } else if (args.length == 2) {
      final leftSnapshot = await readSnapshot(context, args[0], password: password);
      if (leftSnapshot == null) return;

      final rightSnapshot = await readSnapshot(context, args[1], password: password);
      if (rightSnapshot == null) return;

      leftFiles = await _decodeSnapshotFiles(leftSnapshot);
      rightFiles = await _decodeSnapshotFiles(rightSnapshot);
      leftLabel = 'snapshot:${args[0]}';
      rightLabel = 'snapshot:${args[1]}';
    } else {
      print('❌ Usage: vcs diff [snapshot_id_1] [snapshot_id_2]'.red);
      return;
    }

    await _printDiffBetweenFileMaps(
      leftFiles,
      rightFiles,
      leftLabel: leftLabel,
      rightLabel: rightLabel,
    );
  }

  Future<void> push(String message, {String? author}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final password = askPassword();
    if (password == null) return;

    await _withLock(context.remoteRepoDir, () async {
      final currentFingerprint = await buildFingerprint(_cwd);

      Map<String, String> lastFingerprint = {};
      if (context.remoteMeta.logs.isNotEmpty) {
        final lastEntry = context.remoteMeta.logs.first;
        final lastSnapshot = await readSnapshot(
          context,
          lastEntry.id,
          password: password,
        );
        if (lastSnapshot == null) return;
        lastFingerprint = Map<String, String>.from(lastSnapshot.fingerprint);
      }

      final changes = diffFingerprints(lastFingerprint, currentFingerprint);
      if (changes.isEmpty && context.remoteMeta.logs.isNotEmpty) {
        print('ℹ️ No changes to save.');
        return;
      }

      final zipBytes = await _createZipFromCurrentProject();
      final encrypted = await _encryptSnapshot(
        zipBytes: zipBytes,
        message: message,
        author: author,
        fingerprint: currentFingerprint,
        password: password,
      );

      final snapshotId = DateTime.now().millisecondsSinceEpoch.toString();
      final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
      await snapshotsDir.create(recursive: true);

      final snapshotFile = File(p.join(snapshotsDir.path, '$snapshotId.vcs'));
      await snapshotFile.writeAsBytes(encrypted, flush: true);

      final entry = SnapshotLogEntry(
        id: snapshotId,
        message: message,
        author: author,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        fileName: '$snapshotId.vcs',
        changeSummary: changes.map((e) => e.toTag()).toList(),
      );

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        logs: [entry, ...context.remoteMeta.logs],
      );

      await _atomicWriteString(
        File(p.join(context.remoteRepoDir.path, remoteMetaFileName)),
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
      );

      print('✅ Snapshot saved successfully. ID=$snapshotId');
    });
  }

  Future<void> log() async {
    final context = await loadRepoContext();
    if (context == null) return;

    if (context.remoteMeta.logs.isEmpty) {
      print('ℹ️ ${"No snapshots yet.".yellow}');
      return;
    }

    print('\n📜 ${"Snapshot history".cyan}');
    print('═' * 60);

    final logs = context.remoteMeta.logs.reversed.toList();

    for (var i = 0; i < logs.length; i++) {
      final entry = logs[i];
      final createdAt = _formatDateForList(entry.createdAt);
      final author = entry.author ?? '-';

      final isLatest = i == logs.length - 1;

      print(
        '[${i.toString().padLeft(2, '0')}] '
        '${entry.id.green}'
        '${isLatest ? " ${"(latest)".cyan}" : ""}',
      );

      print('     ${"Date:".yellow.padRight(10)} $createdAt');
      print('     ${"Author:".yellow.padRight(10)} $author');
      print('     ${"Message:".yellow.padRight(10)} ${entry.message.cyan}');

      if (entry.changeSummary.isEmpty) {
        print('     ${"Changes:".yellow.padRight(10)} ${"(none)".red}');
      } else {
        print('     ${"Changes:".yellow.padRight(10)}');
        for (final c in entry.changeSummary) {
          if (c.startsWith('[N]')) {
            print('       ${c.green}');
          } else if (c.startsWith('[M]')) {
            print('       ${c.yellow}');
          } else if (c.startsWith('[D]')) {
            print('       ${c.red}');
          } else {
            print('       $c');
          }
        }
      }

      if (i != logs.length - 1) {
        print('─' * 60);
      }
    }

    print('═' * 60);
  }

  Future<void> showSnapshot(String snapshotId) async {
    final context = await loadRepoContext();
    if (context == null) return;

    SnapshotLogEntry? entry;
    for (final item in context.remoteMeta.logs) {
      if (item.id == snapshotId) {
        entry = item;
        break;
      }
    }

    if (entry == null) {
      print('❌ ${"Snapshot not found:".red} $snapshotId');
      return;
    }

    final file = File(p.join(context.remoteRepoDir.path, 'snapshots', entry.fileName));
    final size = file.existsSync() ? file.lengthSync() : 0;

    final createdAt = _formatDateForList(entry.createdAt);
    final author = entry.author ?? '-';

    print('\n🔎 ${"Snapshot details".cyan}');
    print('═' * 60);

    print('${"ID:".yellow.padRight(12)} ${entry.id.green}');
    print('${"Project:".yellow.padRight(12)} ${context.remoteMeta.projectName.green}');
    print('${"Created:".yellow.padRight(12)} $createdAt');
    print('${"Author:".yellow.padRight(12)} $author');
    print('${"Message:".yellow.padRight(12)} ${entry.message.cyan}');
    print('${"File:".yellow.padRight(12)} ${entry.fileName}');
    print('${"Size:".yellow.padRight(12)} ${_formatBytes(size).green}');
    print('${"Changes:".yellow.padRight(12)} ${entry.changeSummary.length.toString().green}');

    print('');
    print('${"Changed files".yellow}');
    print('─' * 60);

    if (entry.changeSummary.isEmpty) {
      print('  ${"(none)".red}');
    } else {
      for (final c in entry.changeSummary) {
        if (c.startsWith('[N]')) {
          print('  ${c.green}');
        } else if (c.startsWith('[M]')) {
          print('  ${c.yellow}');
        } else if (c.startsWith('[D]')) {
          print('  ${c.red}');
        } else {
          print('  $c');
        }
      }
    }

    print('═' * 60);
  }

  Future<void> verify(String snapshotId) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshot(
      context,
      snapshotId,
      password: password,
    );
    if (snapshot == null) return;

    try {
      ZipDecoder().decodeBytes(snapshot.zipBytes, verify: true);
      print('✅ Snapshot is valid and decryptable.');
    } catch (e) {
      print('❌ Snapshot verification failed: $e');
    }
  }

  Future<void> doctor() async {
    print('\n🩺 ${"Repository diagnostics".cyan}');
    print('═' * 60);

    var okCount = 0;
    var warnCount = 0;

    void check(bool ok, String label, {String? details}) {
      if (ok) {
        okCount++;
        print('  ${"✔".green} ${label.green}');
      } else {
        warnCount++;
        print('  ${"⚠".yellow} ${label.yellow}');
      }

      if (details != null && details.trim().isNotEmpty) {
        print('      ${details}');
      }
    }

    print('\n${"Local project".yellow}');
    print('─' * 60);

    final localInitialized = _localRepoFile.existsSync();
    check(
      localInitialized,
      'Local repository metadata',
      details: localInitialized ? _localRepoFile.path : 'File not found: ${_localRepoFile.path}',
    );

    final gitignoreExists = _gitignoreFile.existsSync();
    check(
      gitignoreExists,
      '.gitignore detected',
      details: gitignoreExists ? _gitignoreFile.path : 'No .gitignore in current project root',
    );

    final usb = await findUsbDrive();
    if (usb == null) {
      print('\n${"USB / Remote storage".yellow}');
      print('─' * 60);
      check(false, 'Prepared USB drive available', details: 'No drive marker found.');

      print('\n${"Summary".yellow}');
      print('─' * 60);
      print('  ${"OK:".green} $okCount');
      print('  ${"Warnings:".yellow} $warnCount');
      print('');
      return;
    }

    print('\n${"USB / Remote storage".yellow}');
    print('─' * 60);

    check(true, 'Prepared USB drive available', details: usb.path);

    final reposDir = Directory(p.join(usb.path, remoteReposDir));
    check(
      reposDir.existsSync(),
      'Repositories directory exists',
      details: reposDir.path,
    );

    if (!localInitialized) {
      print('\n${"Binding / Remote repository".yellow}');
      print('─' * 60);
      check(
        false,
        'Project is not initialized locally',
        details: 'Remote binding checks stop here because .vcs/repo.json is missing.',
      );

      print('\n${"Summary".yellow}');
      print('─' * 60);
      print('  ${"OK:".green} $okCount');
      print('  ${"Warnings:".yellow} $warnCount');
      print('');
      return;
    }

    print('\n${"Binding / Remote repository".yellow}');
    print('─' * 60);

    final localMeta = jsonDecode(await _localRepoFile.readAsString()) as Map<String, dynamic>;
    final repoId = localMeta['repo_id']?.toString();

    if (repoId == null || repoId.isEmpty) {
      check(false, 'Local repo_id is valid', details: 'repo_id is missing or empty.');
      print('\n${"Summary".yellow}');
      print('─' * 60);
      print('  ${"OK:".green} $okCount');
      print('  ${"Warnings:".yellow} $warnCount');
      print('');
      return;
    }

    check(true, 'Local repo_id is valid', details: repoId);

    final remoteRepoDir = Directory(p.join(usb.path, remoteReposDir, repoId));
    if (!remoteRepoDir.existsSync()) {
      check(false, 'Remote repository exists on USB', details: remoteRepoDir.path);

      print('\n${"Summary".yellow}');
      print('─' * 60);
      print('  ${"OK:".green} $okCount');
      print('  ${"Warnings:".yellow} $warnCount');
      print('');
      return;
    }

    check(true, 'Remote repository exists on USB', details: remoteRepoDir.path);

    final metaFile = File(p.join(remoteRepoDir.path, remoteMetaFileName));
    if (!metaFile.existsSync()) {
      check(false, 'Remote metadata file exists', details: metaFile.path);

      print('\n${"Summary".yellow}');
      print('─' * 60);
      print('  ${"OK:".green} $okCount');
      print('  ${"Warnings:".yellow} $warnCount');
      print('');
      return;
    }

    check(true, 'Remote metadata file exists', details: metaFile.path);

    RepoMeta meta;
    try {
      final jsonMap = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      meta = RepoMeta.fromJson(jsonMap);
      check(true, 'Remote metadata is readable');
    } catch (e) {
      check(false, 'Remote metadata is readable', details: e.toString());

      print('\n${"Summary".yellow}');
      print('─' * 60);
      print('  ${"OK:".green} $okCount');
      print('  ${"Warnings:".yellow} $warnCount');
      print('');
      return;
    }

    print('\n${"Snapshots".yellow}');
    print('─' * 60);

    check(
      meta.logs.isNotEmpty,
      'Repository has snapshots',
      details: 'Count: ${meta.logs.length}',
    );

    final lockFile = File(p.join(remoteRepoDir.path, lockFileName));
    if (lockFile.existsSync()) {
      final age = DateTime.now().difference(lockFile.statSync().modified);
      check(
        false,
        'No active lock file',
        details: 'Lock present: ${lockFile.path} (age ${age.inMinutes} min)',
      );
    } else {
      check(true, 'No active lock file');
    }

    final snapshotsDir = Directory(p.join(remoteRepoDir.path, 'snapshots'));
    check(
      snapshotsDir.existsSync(),
      'Snapshots directory exists',
      details: snapshotsDir.path,
    );

    if (meta.logs.isNotEmpty) {
      final missing = <String>[];
      for (final entry in meta.logs) {
        final file = File(p.join(remoteRepoDir.path, 'snapshots', entry.fileName));
        if (!file.existsSync()) {
          missing.add(entry.fileName);
        }
      }

      if (missing.isEmpty) {
        check(true, 'All snapshot files referenced in metadata exist');
      } else {
        check(
          false,
          'All snapshot files referenced in metadata exist',
          details: 'Missing: ${missing.join(', ')}',
        );
      }
    }

    print('\n${"Summary".yellow}');
    print('─' * 60);
    print('  ${"OK:".green} $okCount');
    print('  ${"Warnings:".yellow} $warnCount');

    if (warnCount == 0) {
      print('  ${"Status: healthy".green}');
    } else {
      print('  ${"Status: attention needed".yellow}');
    }

    print('');
  }

  Future<void> stats() async {
    final context = await loadRepoContext();
    if (context == null) return;

    final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
    final logs = context.remoteMeta.logs;

    int totalBytes = 0;
    int largestBytes = 0;
    String? largestId;

    if (snapshotsDir.existsSync()) {
      for (final entry in logs) {
        final file = File(p.join(snapshotsDir.path, entry.fileName));
        if (!file.existsSync()) continue;

        final size = file.lengthSync();
        totalBytes += size;

        if (size > largestBytes) {
          largestBytes = size;
          largestId = entry.id;
        }
      }
    }

    final createdAt = _formatDateForList(context.remoteMeta.createdAt);
    final updatedAt = _formatDateForList(context.remoteMeta.updatedAt);

    print('\n📊 ${"Repository statistics".cyan}');
    print('─' * 50);

    print('${"Project:".yellow.padRight(18)} ${context.remoteMeta.projectName.green}');
    print('${"Repo ID:".yellow.padRight(18)} ${context.remoteMeta.repoId}');
    print('${"Format version:".yellow.padRight(18)} ${context.remoteMeta.formatVersion}');
    print('${"Created:".yellow.padRight(18)} $createdAt');
    print('${"Updated:".yellow.padRight(18)} $updatedAt');

    print('');
    print('${"Snapshots:".yellow.padRight(18)} ${logs.length.toString().green}');
    print('${"Total size:".yellow.padRight(18)} ${_formatBytes(totalBytes).green}');
    print(
      '${"Largest snapshot:".yellow.padRight(18)} '
      '${largestId != null ? largestId.green : "(none)".red} '
      '(${_formatBytes(largestBytes)})',
    );

    if (logs.isNotEmpty) {
      final newest = logs.first;
      final oldest = logs.last;

      print('${"Newest snapshot:".yellow.padRight(18)} ${newest.id.green}');
      print('${"Newest date:".yellow.padRight(18)} ${_formatDateForList(newest.createdAt)}');

      print('${"Oldest snapshot:".yellow.padRight(18)} ${oldest.id.green}');
      print('${"Oldest date:".yellow.padRight(18)} ${_formatDateForList(oldest.createdAt)}');
    }

    print('─' * 50);
  }

  Future<void> prune({int? keep, int? olderThanDays}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    if (context.remoteMeta.logs.isEmpty) {
      print('ℹ️ No snapshots to prune.');
      return;
    }

    if (keep == null && olderThanDays == null) {
      print('❌ Use --keep <n> and/or --older-than <days>.');
      return;
    }

    final now = DateTime.now().toUtc();
    final logs = List<SnapshotLogEntry>.from(context.remoteMeta.logs);
    final toDelete = <SnapshotLogEntry>{};

    if (olderThanDays != null) {
      for (final entry in logs) {
        final created = DateTime.tryParse(entry.createdAt)?.toUtc();
        if (created == null) continue;
        final age = now.difference(created).inDays;
        if (age > olderThanDays) {
          toDelete.add(entry);
        }
      }
    }

    if (keep != null && keep >= 0 && logs.length > keep) {
      for (var i = keep; i < logs.length; i++) {
        toDelete.add(logs[i]);
      }
    }

    if (toDelete.length >= logs.length && logs.isNotEmpty) {
      toDelete.remove(logs.first);
    }

    if (toDelete.isEmpty) {
      print('ℹ️ Nothing to prune.');
      return;
    }

    print('Snapshots selected for deletion:');
    for (final entry in toDelete) {
      print('  ${entry.id} | ${entry.createdAt} | ${entry.message}');
    }

    stdout.write('Delete ${toDelete.length} snapshots? (y/N): ');
    if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') {
      print('Cancelled.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      for (final entry in toDelete) {
        final file = File(p.join(context.remoteRepoDir.path, 'snapshots', entry.fileName));
        if (file.existsSync()) {
          file.deleteSync();
        }
      }

      final remaining = logs.where((e) => !toDelete.contains(e)).toList();
      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        logs: remaining,
      );

      await _atomicWriteString(
        File(p.join(context.remoteRepoDir.path, remoteMetaFileName)),
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
      );

      print('✅ Pruned ${toDelete.length} snapshots.');
      print('ℹ️ Remaining snapshots: ${remaining.length}');
    });
  }

  Future<void> pull() async {
    final context = await loadRepoContext();
    if (context == null) return;

    if (context.remoteMeta.logs.isEmpty) {
      print('ℹ️ No snapshots available.');
      return;
    }

    final password = askPassword();
    if (password == null) return;

    await revertWithPassword(context.remoteMeta.logs.first.id, password);
  }

  Future<void> revert(String snapshotId) async {
    final password = askPassword();
    if (password == null) return;

    await revertWithPassword(snapshotId, password);
  }

  Future<void> revertWithPassword(String snapshotId, String password) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final snapshot = await readSnapshot(
      context,
      snapshotId,
      password: password,
    );
    if (snapshot == null) return;

    stdout.write(
      '⚠️ This will replace tracked content in the current working directory.\n'
      'A local backup will be created first.\n'
      'Continue? (y/N): ',
    );
    if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') {
      print('Cancelled.');
      return;
    }

    final tempRestoreDir = await Directory(
      p.join(_localMetaDir.path, 'tmp_restore_${DateTime.now().millisecondsSinceEpoch}'),
    ).create(recursive: true);

    final backupDir = Directory(
      p.join(_localMetaDir.path, 'backup_before_restore_${DateTime.now().millisecondsSinceEpoch}'),
    );

    try {
      await _extractZipToDirectory(snapshot.zipBytes, tempRestoreDir);

      await _createTrackedBackup(backupDir);

      final currentTracked = await _listTrackedFiles(_cwd);
      for (final rel in currentTracked) {
        final file = File(p.join(_cwd.path, rel));
        if (file.existsSync()) {
          file.deleteSync();
        }
      }

      await _copyTrackedFiles(tempRestoreDir, _cwd);

      print('✅ Restore completed.');
      print('🛟 Previous state backed up at: ${backupDir.path}');
    } catch (e) {
      print('❌ Restore failed: $e');
      print('⚠️ Trying to recover previous backup...');
      try {
        final currentTracked = await _listTrackedFiles(_cwd);
        for (final rel in currentTracked) {
          final file = File(p.join(_cwd.path, rel));
          if (file.existsSync()) {
            file.deleteSync();
          }
        }
        if (backupDir.existsSync()) {
          await _copyTrackedFiles(backupDir, _cwd);
          print('✅ Previous state recovered from local backup.');
        } else {
          print('❌ No backup found for recovery.');
        }
      } catch (recoveryError) {
        print('❌ Recovery failed: $recoveryError');
      }
    } finally {
      if (tempRestoreDir.existsSync()) {
        tempRestoreDir.deleteSync(recursive: true);
      }
    }
  }

  Future<void> restoreTo(String snapshotId, String targetDir) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshot(
      context,
      snapshotId,
      password: password,
    );
    if (snapshot == null) return;

    final dest = Directory(targetDir);
    if (dest.existsSync() && dest.listSync().isNotEmpty) {
      stdout.write('⚠️ Target directory is not empty. Continue? (y/N): ');
      if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') {
        print('Cancelled.');
        return;
      }
    }

    await dest.create(recursive: true);
    await _extractZipToDirectory(snapshot.zipBytes, dest);
    print('✅ Snapshot restored into ${dest.path}');
  }

  Future<void> clearHistory() async {
    final context = await loadRepoContext();
    if (context == null) return;

    stdout.write('⚠️ Delete snapshot history from USB? (y/N): ');
    if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') {
      print('Cancelled.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
      if (snapshotsDir.existsSync()) {
        snapshotsDir.deleteSync(recursive: true);
      }
      await snapshotsDir.create(recursive: true);

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        logs: [],
      );

      await _atomicWriteString(
        File(p.join(context.remoteRepoDir.path, remoteMetaFileName)),
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
      );

      print('🗑️ History deleted.');
    });
  }

  Future<void> purge() async {
    final context = await loadRepoContext();
    if (context == null) return;

    stdout.write('🚨 This will delete the remote repo from USB. Continue? (y/N): ');
    if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') {
      print('Cancelled.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      if (context.remoteRepoDir.existsSync()) {
        context.remoteRepoDir.deleteSync(recursive: true);
      }
      print('💀 Remote repo deleted from USB.');
    });
  }

  Future<List<Directory>> _listCandidateDrives() async {
    final candidates = <Directory>[];

    if (Platform.isWindows) {
      for (final letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
        final dir = Directory('$letter:/');
        if (dir.existsSync()) {
          candidates.add(dir);
        }
      }
    } else if (Platform.isMacOS) {
      final root = Directory('/Volumes');
      if (root.existsSync()) {
        candidates.addAll(root.listSync().whereType<Directory>());
      }
    } else if (Platform.isLinux) {
      final user = Platform.environment['USER'] ?? '';
      for (final base in ['/media/$user', '/run/media/$user']) {
        final root = Directory(base);
        if (root.existsSync()) {
          candidates.addAll(root.listSync().whereType<Directory>());
        }
      }
    }

    return candidates;
  }

  Future<Directory?> findUsbDrive() async {
    final candidates = await _listCandidateDrives();
    final prepared = candidates
        .where((d) => File(p.join(d.path, driveMarkerFile)).existsSync())
        .toList();

    if (prepared.isEmpty) {
      return null;
    }

    if (prepared.length == 1) {
      return prepared.first;
    }

    print('Multiple prepared drives detected:');
    for (var i = 0; i < prepared.length; i++) {
      print('[$i] ${prepared[i].path}');
    }
    stdout.write('Select one to use: ');
    final raw = stdin.readLineSync()?.trim() ?? '';
    final index = int.tryParse(raw);
    if (index == null || index < 0 || index >= prepared.length) {
      print('❌ Invalid selection.');
      return null;
    }
    return prepared[index];
  }

  Future<RepoContext?> loadRepoContext() async {
    if (!_localRepoFile.existsSync()) {
      print('❌ This project is not initialized. Run init first.');
      return null;
    }

    final usb = await findUsbDrive();
    if (usb == null) {
      print('❌ No prepared USB drive found.');
      return null;
    }

    final localMeta = jsonDecode(await _localRepoFile.readAsString()) as Map<String, dynamic>;
    final repoId = localMeta['repo_id']?.toString();
    if (repoId == null || repoId.isEmpty) {
      print('❌ Invalid local repo_id.');
      return null;
    }

    final remoteRepoDir = Directory(p.join(usb.path, remoteReposDir, repoId));
    if (!remoteRepoDir.existsSync()) {
      print('❌ Repo not found on USB drive.');
      return null;
    }

    final metaFile = File(p.join(remoteRepoDir.path, remoteMetaFileName));
    if (!metaFile.existsSync()) {
      print('❌ Remote metadata file is missing.');
      return null;
    }

    final remoteMetaJson = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    return RepoContext(
      usbDrive: usb,
      remoteRepoDir: remoteRepoDir,
      localMeta: localMeta,
      remoteMeta: RepoMeta.fromJson(remoteMetaJson),
    );
  }

  Future<List<RemoteRepoInfo>> _loadRemoteRepos(Directory usb) async {
    final reposDir = Directory(p.join(usb.path, remoteReposDir));
    if (!reposDir.existsSync()) {
      return [];
    }

    final repos = <RemoteRepoInfo>[];

    for (final entity in reposDir.listSync()) {
      if (entity is! Directory) continue;

      final metaFile = File(p.join(entity.path, remoteMetaFileName));
      if (!metaFile.existsSync()) continue;

      try {
        final jsonMap = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final meta = RepoMeta.fromJson(jsonMap);
        repos.add(RemoteRepoInfo(repoDir: entity, meta: meta));
      } catch (_) {}
    }

    repos.sort((a, b) => b.meta.updatedAt.compareTo(a.meta.updatedAt));
    return repos;
  }

  RemoteRepoInfo? _selectRemoteRepo(List<RemoteRepoInfo> repos, String? repoId) {
    if (repoId != null && repoId.trim().isNotEmpty) {
      for (final repo in repos) {
        if (repo.meta.repoId == repoId.trim()) {
          return repo;
        }
      }
      print('❌ Repository not found: $repoId');
      return null;
    }

    print('Available repositories:');
    for (var i = 0; i < repos.length; i++) {
      final repo = repos[i];
      print('[$i] ${repo.meta.projectName} | repo_id=${repo.meta.repoId} | updated=${repo.meta.updatedAt}');
    }

    stdout.write('Select repository index: ');
    final raw = stdin.readLineSync()?.trim() ?? '';
    final index = int.tryParse(raw);
    if (index == null || index < 0 || index >= repos.length) {
      print('❌ Invalid selection.');
      return null;
    }
    return repos[index];
  }

  Future<List<IgnoreRule>> _loadGitignoreRules() async {
    if (!_gitignoreFile.existsSync()) {
      return [];
    }

    final lines = await _gitignoreFile.readAsLines();
    final rules = <IgnoreRule>[];

    for (final raw in lines) {
      final parsed = IgnoreRule.parse(raw);
      if (parsed != null) {
        rules.add(parsed);
      }
    }

    return rules;
  }

  Future<bool> _isIgnoredPath(String relativePath) async {
    final normalized = _normalizeRelativePath(relativePath);
    final basename = p.basename(normalized);

    if (_matchesInternalIgnore(normalized, basename)) {
      return true;
    }

    final rules = await _loadGitignoreRules();
    var ignored = false;

    for (final rule in rules) {
      if (rule.matches(normalized, basename)) {
        ignored = !rule.negated;
      }
    }

    return ignored;
  }

  bool _matchesInternalIgnore(String normalizedPath, String basename) {
    final parts = normalizedPath.split('/');

    for (final name in internalIgnoredNames) {
      if (basename == name || parts.contains(name)) {
        return true;
      }
    }

    return false;
  }

  String _normalizeRelativePath(String input) {
    return input.replaceAll('\\', '/');
  }

  Future<Map<String, String>> buildFingerprint(Directory dir) async {
    final out = <String, String>{};

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final rel = _normalizeRelativePath(p.relative(entity.path, from: dir.path));
      if (await _isIgnoredPath(rel)) continue;

      try {
        final bytes = await entity.readAsBytes();
        out[rel] = hash.sha256.convert(bytes).toString();
      } catch (e) {
        print("⚠️ Could not read '$rel': $e");
      }
    }

    return out;
  }

  Future<Map<String, Uint8List>> _readCurrentProjectFiles() async {
    final out = <String, Uint8List>{};

    await for (final entity in _cwd.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final rel = _normalizeRelativePath(p.relative(entity.path, from: _cwd.path));
      if (await _isIgnoredPath(rel)) continue;

      try {
        out[rel] = Uint8List.fromList(await entity.readAsBytes());
      } catch (_) {}
    }

    return out;
  }

  Future<Map<String, Uint8List>> _decodeSnapshotFiles(
    DecryptedSnapshot snapshot,
  ) async {
    final archive = ZipDecoder().decodeBytes(
      snapshot.zipBytes,
      verify: true,
    );

    final files = <String, Uint8List>{};

    for (final file in archive) {
      if (!file.isFile) continue;

      files[file.name.replaceAll('\\', '/')] =
          Uint8List.fromList(file.content);
    }

    return files;
  }

  List<FileChange> diffFingerprints(
    Map<String, String> previous,
    Map<String, String> current,
  ) {
    final changes = <FileChange>[];

    for (final entry in current.entries) {
      if (!previous.containsKey(entry.key)) {
        changes.add(FileChange(ChangeKind.added, entry.key));
      } else if (previous[entry.key] != entry.value) {
        changes.add(FileChange(ChangeKind.modified, entry.key));
      }
    }

    for (final entry in previous.entries) {
      if (!current.containsKey(entry.key)) {
        changes.add(FileChange(ChangeKind.deleted, entry.key));
      }
    }

    changes.sort((a, b) => a.path.compareTo(b.path));
    return changes;
  }

  Future<void> _printDiffBetweenFileMaps(
    Map<String, Uint8List> left,
    Map<String, Uint8List> right, {
    required String leftLabel,
    required String rightLabel,
  }) async {
    final allPaths = <String>{...left.keys, ...right.keys}.toList()..sort();

    if (allPaths.isEmpty) {
      print('ℹ️ ${"No files to compare.".yellow}');
      return;
    }

    final newFiles = <String>[];
    final deletedFiles = <String>[];
    final modifiedFiles = <String>[];

    for (final path in allPaths) {
      final a = left[path];
      final b = right[path];

      if (a == null && b != null) {
        newFiles.add(path);
        continue;
      }

      if (a != null && b == null) {
        deletedFiles.add(path);
        continue;
      }

      if (a == null || b == null) {
        continue;
      }

      if (!_bytesEqual(a, b)) {
        modifiedFiles.add(path);
      }
    }

    final totalChanges = newFiles.length + modifiedFiles.length + deletedFiles.length;

    print('\n🔍 ${"Diff".cyan}');
    print('═' * 60);
    print('${"From:".yellow.padRight(10)} $leftLabel');
    print('${"To:".yellow.padRight(10)} $rightLabel');
    print('${"Changes:".yellow.padRight(10)} ${totalChanges.toString().green}');
    print('${"New:".yellow.padRight(10)} ${newFiles.length.toString().green}');
    print('${"Modified:".yellow.padRight(10)} ${modifiedFiles.length.toString().yellow}');
    print('${"Deleted:".yellow.padRight(10)} ${deletedFiles.length.toString().red}');
    print('═' * 60);

    if (totalChanges == 0) {
      print('✨ ${"No differences found.".green}\n');
      return;
    }

    if (newFiles.isNotEmpty) {
      print('\n📄 ${"New files".green}');
      print('─' * 60);
      for (final path in newFiles) {
        print('${'[NEW]'.green} $path');
      }
    }

    if (deletedFiles.isNotEmpty) {
      print('\n🗑️ ${"Deleted files".red}');
      print('─' * 60);
      for (final path in deletedFiles) {
        print('${'[DEL]'.red} $path');
      }
    }

    if (modifiedFiles.isNotEmpty) {
      print('\n✏️ ${"Modified files".yellow}');
      print('─' * 60);

      for (final path in modifiedFiles) {
        final a = left[path]!;
        final b = right[path]!;

        print('${'[MOD]'.yellow} ${path.cyan}');
        print('─' * 60);

        final aText = _tryDecodeUtf8(a);
        final bText = _tryDecodeUtf8(b);

        if (aText == null || bText == null) {
          print('  ${"(binary or non-UTF8 content changed)".yellow}');
          print('');
          continue;
        }

        final lines = _simpleLineDiff(aText, bText);

        if (lines.isEmpty) {
          print('  ${"(content changed, but no line diff available)".yellow}');
          print('');
          continue;
        }

        final blocks = _splitDiffIntoBlocks(lines);
        const maxBlocksPerFile = 3;
        const maxLinesPerFile = 40;

        var printedLines = 0;
        var shownBlocks = 0;

        for (var i = 0; i < blocks.length; i++) {
          if (shownBlocks >= maxBlocksPerFile) {
            final remainingBlocks = blocks.length - shownBlocks;
            print('  ${"... ${remainingBlocks} more diff block(s) hidden ...".yellow}');
            break;
          }

          final block = blocks[i];
          shownBlocks++;

          if (i > 0) {
            print('  ${"... skipped unchanged lines ...".yellow}');
          }

          for (final line in block) {
            if (printedLines >= maxLinesPerFile) {
              final remainingLines = lines.length - printedLines;
              if (remainingLines > 0) {
                print('  ${"... diff truncated (${remainingLines} more line(s)) ...".yellow}');
              }
              break;
            }

            if (line.startsWith('+')) {
              print('  ${line.green}');
            } else if (line.startsWith('-')) {
              print('  ${line.red}');
            } else {
              print('  $line');
            }

            printedLines++;
          }

          if (printedLines >= maxLinesPerFile) {
            break;
          }
        }

        print('');
      }
    }

    print('═' * 60);
    print('');
  }

  List<List<String>> _splitDiffIntoBlocks(List<String> lines) {
    final blocks = <List<String>>[];
    var current = <String>[];

    for (final line in lines) {
      if (line.trim() == '...') {
        if (current.isNotEmpty) {
          blocks.add(current);
          current = <String>[];
        }
        continue;
      }

      current.add(line);
    }

    if (current.isNotEmpty) {
      blocks.add(current);
    }

    return blocks;
  }

  List<String> _simpleLineDiff(String a, String b) {
    final left = const LineSplitter().convert(a);
    final right = const LineSplitter().convert(b);

    if (_listEquals(left, right)) {
      return [];
    }

    final rawLines = _buildRawDiffLines(left, right);
    return _compressDiffIntoBlocks(rawLines, context: 1);
  }

  List<_DiffLine> _buildRawDiffLines(List<String> left, List<String> right) {
    final lcs = List.generate(
      left.length + 1,
      (_) => List<int>.filled(right.length + 1, 0),
    );

    for (var i = left.length - 1; i >= 0; i--) {
      for (var j = right.length - 1; j >= 0; j--) {
        if (left[i] == right[j]) {
          lcs[i][j] = lcs[i + 1][j + 1] + 1;
        } else {
          lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1]);
        }
      }
    }

    final output = <_DiffLine>[];
    var i = 0;
    var j = 0;

    while (i < left.length && j < right.length) {
      if (left[i] == right[j]) {
        output.add(_DiffLine.context(left[i]));
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        output.add(_DiffLine.removed(left[i]));
        i++;
      } else {
        output.add(_DiffLine.added(right[j]));
        j++;
      }
    }

    while (i < left.length) {
      output.add(_DiffLine.removed(left[i]));
      i++;
    }

    while (j < right.length) {
      output.add(_DiffLine.added(right[j]));
      j++;
    }

    return output;
  }

  List<String> _compressDiffIntoBlocks(List<_DiffLine> lines, {int context = 2}) {
    if (lines.isEmpty) return [];

    final changeIndexes = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].type != _DiffLineType.context) {
        changeIndexes.add(i);
      }
    }

    if (changeIndexes.isEmpty) {
      return [];
    }

    final ranges = <_Range>[];

    for (final index in changeIndexes) {
      final start = max(0, index - context);
      final end = min(lines.length - 1, index + context);

      if (ranges.isEmpty) {
        ranges.add(_Range(start, end));
        continue;
      }

      final last = ranges.last;
      if (start <= last.end + 1) {
        last.end = max(last.end, end);
      } else {
        ranges.add(_Range(start, end));
      }
    }

    final output = <String>[];

    for (var i = 0; i < ranges.length; i++) {
      final range = ranges[i];

      for (var j = range.start; j <= range.end; j++) {
        final line = lines[j];
        switch (line.type) {
          case _DiffLineType.context:
            output.add('  ${line.text}');
            break;
          case _DiffLineType.added:
            output.add('+ ${line.text}');
            break;
          case _DiffLineType.removed:
            output.add('- ${line.text}');
            break;
        }
      }

      if (i != ranges.length - 1) {
        output.add('  ...');
      }
    }

    return output;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String? _tryDecodeUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _createZipFromCurrentProject() async {
    final archive = Archive();

    await for (final entity in _cwd.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final rel = _normalizeRelativePath(p.relative(entity.path, from: _cwd.path));
      if (await _isIgnoredPath(rel)) continue;

      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }

    final zip = ZipEncoder().encode(archive);
    return Uint8List.fromList(zip);
  }

  Future<Uint8List> _encryptSnapshot({
    required Uint8List zipBytes,
    required String message,
    required String password,
    Map<String, String>? fingerprint,
    String? author,
  }) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );

    final algorithm = crypto_alg.Pbkdf2(
      macAlgorithm: crypto_alg.Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    );

    final secretKey = await algorithm.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );

    final payload = {
      'format_version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'message': message,
      'author': author,
      'fingerprint': fingerprint ?? <String, String>{},
      'zip_base64': base64Encode(zipBytes),
    };

    final plainBytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final aes = crypto_alg.AesGcm.with256bits();

    final secretBox = await aes.encrypt(
      plainBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    final wrapper = {
      'alg': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': 120000,
      'salt_b64': base64Encode(salt),
      'nonce_b64': base64Encode(secretBox.nonce),
      'cipher_b64': base64Encode(secretBox.cipherText),
      'mac_b64': base64Encode(secretBox.mac.bytes),
    };

    return Uint8List.fromList(utf8.encode(jsonEncode(wrapper)));
  }

  Future<DecryptedSnapshot?> readSnapshot(
    RepoContext context,
    String snapshotId, {
    required String password,
  }) async {
    return readSnapshotByMeta(
      remoteRepoDir: context.remoteRepoDir,
      remoteMeta: context.remoteMeta,
      snapshotId: snapshotId,
      password: password,
    );
  }

  Future<DecryptedSnapshot?> readSnapshotByMeta({
    required Directory remoteRepoDir,
    required RepoMeta remoteMeta,
    required String snapshotId,
    required String password,
  }) async {
    SnapshotLogEntry? entry;
    for (final item in remoteMeta.logs) {
      if (item.id == snapshotId) {
        entry = item;
        break;
      }
    }

    if (entry == null) {
      print('❌ Snapshot ID not found: $snapshotId');
      return null;
    }

    final file = File(p.join(remoteRepoDir.path, 'snapshots', entry.fileName));
    if (!file.existsSync()) {
      print('❌ Snapshot file is missing: ${entry.fileName}');
      return null;
    }

    try {
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      final salt = base64Decode(raw['salt_b64'] as String);
      final nonce = base64Decode(raw['nonce_b64'] as String);
      final cipher = base64Decode(raw['cipher_b64'] as String);
      final mac = base64Decode(raw['mac_b64'] as String);
      final iterations = raw['iterations'] as int;

      final algorithm = crypto_alg.Pbkdf2(
        macAlgorithm: crypto_alg.Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );

      final secretKey = await algorithm.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );

      final aes = crypto_alg.AesGcm.with256bits();
      final clear = await aes.decrypt(
        crypto_alg.SecretBox(
          cipher,
          nonce: nonce,
          mac: crypto_alg.Mac(mac),
        ),
        secretKey: secretKey,
      );

      final payload = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      final zipBytes = base64Decode(payload['zip_base64'] as String);
      final fingerprint = Map<String, String>.from(payload['fingerprint'] as Map);

      return DecryptedSnapshot(
        zipBytes: Uint8List.fromList(zipBytes),
        fingerprint: fingerprint,
        message: payload['message']?.toString(),
        author: payload['author']?.toString(),
        createdAt: payload['created_at']?.toString(),
      );
    } on crypto_alg.SecretBoxAuthenticationError {
      print('❌ Wrong password or tampered snapshot.');
      return null;
    } catch (e) {
      print('❌ Could not read snapshot: $e');
      return null;
    }
  }

  Future<void> _extractZipToDirectory(Uint8List zipBytes, Directory dest) async {
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);

    for (final file in archive) {
      final safePath = p.normalize(p.join(dest.path, file.name));
      if (!p.isWithin(dest.path, safePath) && safePath != dest.path) {
        throw Exception('Unsafe ZIP entry detected: ${file.name}');
      }

      if (file.isFile) {
        final outFile = File(safePath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content, flush: true);
      } else {
        await Directory(safePath).create(recursive: true);
      }
    }
  }

  Future<List<String>> _listTrackedFiles(Directory dir) async {
    final list = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = _normalizeRelativePath(p.relative(entity.path, from: dir.path));
      if (await _isIgnoredPath(rel)) continue;
      list.add(rel);
    }
    list.sort();
    return list;
  }

  Future<void> _copyTrackedFiles(Directory from, Directory to) async {
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = _normalizeRelativePath(p.relative(entity.path, from: from.path));
      if (await _isIgnoredPath(rel)) continue;

      final target = File(p.join(to.path, rel));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(await entity.readAsBytes(), flush: true);
    }
  }

  Future<void> _createTrackedBackup(Directory backupDir) async {
    await backupDir.create(recursive: true);
    await _copyTrackedFiles(_cwd, backupDir);
  }

  Future<void> _withLock(Directory repoDir, Future<void> Function() action) async {
    final lockFile = File(p.join(repoDir.path, lockFileName));
    if (lockFile.existsSync()) {
      final age = DateTime.now().difference(lockFile.statSync().modified);
      if (age.inMinutes < 30) {
        throw Exception('Active lock found. Another operation may be running.');
      } else {
        print('⚠️ Stale lock found. Removing it.');
        lockFile.deleteSync();
      }
    }

    await lockFile.writeAsString(
      jsonEncode({
        'pid': pid,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );

    try {
      await action();
    } finally {
      if (lockFile.existsSync()) {
        lockFile.deleteSync();
      }
    }
  }

  Future<void> _atomicWriteString(File file, String content) async {
    final temp = File('${file.path}.tmp');
    await temp.parent.create(recursive: true);
    await temp.writeAsString(content, flush: true);

    if (file.existsSync()) {
      file.deleteSync();
    }
    temp.renameSync(file.path);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _randomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  String? askPassword() {
    stdout.write('🔑 Project password: ');
    final password = _readHiddenLine();
    stdout.writeln();

    if (password.isEmpty) {
      print('❌ Empty password.');
      return null;
    }

    return password;
  }

  String _readHiddenLine() {
    try {
      stdin.echoMode = false;
    } catch (_) {}
    final line = stdin.readLineSync() ?? '';
    try {
      stdin.echoMode = true;
    } catch (_) {}
    return line;
  }

  Future<void> gitPrepare({
    String? snapshotId,
    required String branch,
    bool dryRun = false,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final gitCheck = await _checkGitRepository();
    if (!gitCheck.ok) {
      print('❌ ${gitCheck.message}');
      return;
    }

    if (!await _gitWorkingTreeIsClean()) {
      print('❌ Git working tree is not clean.');
      print('   Commit, stash, or discard your current Git changes before using git-prepare.');
      return;
    }

    if (context.remoteMeta.logs.isEmpty) {
      print('ℹ️ No snapshots available.');
      return;
    }

    final targetId = snapshotId ?? context.remoteMeta.logs.first.id;
    final entry = context.remoteMeta.logs.firstWhere(
      (e) => e.id == targetId,
      orElse: () => throw Exception('Snapshot not found: $targetId'),
    );

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshot(context, targetId, password: password);
    if (snapshot == null) return;

    final branchExists = await _gitBranchExists(branch);

    print('\n🧭 ${"Git prepare".cyan}');
    print('═' * 60);
    print('${"Snapshot:".yellow.padRight(14)} ${entry.id.green}');
    print('${"Message:".yellow.padRight(14)} ${entry.message}');
    print('${"Branch:".yellow.padRight(14)} ${branch.green}');
    print('${"Branch exists:".yellow.padRight(14)} ${branchExists ? "yes".green : "no".yellow}');
    print('${"Commit message:".yellow.padRight(14)} ${_buildPublishCommitMessage(entry)}');
    print('${"Mode:".yellow.padRight(14)} ${dryRun ? "dry-run".yellow : "apply".green}');
    print('═' * 60);

    if (dryRun) {
      print('ℹ️ Dry-run enabled. No files were changed.');
      return;
    }

    if (!confirmAction('Prepare working tree from snapshot ${entry.id} on branch "$branch"?')) {
      print('Cancelled.');
      return;
    }

    await _gitCheckoutBranch(branch);
    await _restoreSnapshotIntoWorkingTree(context, snapshot);

    print('✅ Working tree prepared from snapshot ${entry.id}.');
    print('ℹ️ Next step: review changes, then run "vcs publish ${entry.id} --branch $branch".');
  }

  Future<void> publish({
    String? snapshotId,
    required String branch,
    String remote = 'origin',
    bool dryRun = false,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final gitCheck = await _checkGitRepository();
    if (!gitCheck.ok) {
      print('❌ ${gitCheck.message}');
      return;
    }

    if (!await _gitRemoteExists(remote)) {
      print('❌ Git remote "$remote" was not found.');
      return;
    }

    if (!await _gitWorkingTreeIsClean()) {
      print('❌ Git working tree is not clean.');
      print('   Commit, stash, or discard your current Git changes before using publish.');
      return;
    }

    if (context.remoteMeta.logs.isEmpty) {
      print('ℹ️ No snapshots available.');
      return;
    }

    final targetId = snapshotId ?? context.remoteMeta.logs.first.id;
    final entry = context.remoteMeta.logs.firstWhere(
      (e) => e.id == targetId,
      orElse: () => throw Exception('Snapshot not found: $targetId'),
    );

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshot(context, targetId, password: password);
    if (snapshot == null) return;

    final branchExists = await _gitBranchExists(branch);
    final commitMessage = _buildPublishCommitMessage(entry);

    print('\n🚀 ${"Publish snapshot to Git".cyan}');
    print('═' * 60);
    print('${"Snapshot:".yellow.padRight(14)} ${entry.id.green}');
    print('${"Message:".yellow.padRight(14)} ${entry.message}');
    print('${"Branch:".yellow.padRight(14)} ${branch.green}');
    print('${"Remote:".yellow.padRight(14)} ${remote.green}');
    print('${"Branch exists:".yellow.padRight(14)} ${branchExists ? "yes".green : "no".yellow}');
    print('${"Commit message:".yellow.padRight(14)} $commitMessage');
    print('${"Mode:".yellow.padRight(14)} ${dryRun ? "dry-run".yellow : "publish".green}');
    print('═' * 60);

    if (dryRun) {
      print('ℹ️ Dry-run enabled. No Git commands were executed.');
      return;
    }

    if (!confirmAction('Restore snapshot ${entry.id} into branch "$branch"?')) {
      print('Cancelled.');
      return;
    }

    await _gitCheckoutBranch(branch);
    await _restoreSnapshotIntoWorkingTree(context, snapshot);

    await _gitAddAll();

    final hasChanges = await _gitHasStagedChanges();
    if (!hasChanges) {
      print('ℹ️ No Git changes detected after applying snapshot. Nothing to commit.');
      return;
    }

    if (!confirmAction('Create Git commit now?')) {
      print('Cancelled before commit.');
      return;
    }

    await _gitCommit(commitMessage);

    if (!confirmAction('Push commit to "$remote/$branch" now?')) {
      print('ℹ️ Commit created locally. Push skipped by user.');
      return;
    }

    await _gitPush(remote, branch);

    print('✅ Snapshot ${entry.id} published to Git.');
  }

  Future<void> _restoreSnapshotIntoWorkingTree(
    RepoContext context,
    DecryptedSnapshot snapshot,
  ) async {
    final tempRestoreDir = await Directory(
      p.join(_localMetaDir.path, 'tmp_restore_${DateTime.now().millisecondsSinceEpoch}'),
    ).create(recursive: true);

    final backupDir = Directory(
      p.join(_localMetaDir.path, 'backup_before_git_publish_${DateTime.now().millisecondsSinceEpoch}'),
    );

    try {
      await _extractZipToDirectory(snapshot.zipBytes, tempRestoreDir);

      await _createTrackedBackup(backupDir);

      final currentTracked = await _listTrackedFiles(_cwd);
      for (final rel in currentTracked) {
        final file = File(p.join(_cwd.path, rel));
        if (file.existsSync()) {
          file.deleteSync();
        }
      }

      await _copyTrackedFiles(tempRestoreDir, _cwd);
    } catch (e) {
      print('❌ Restore into working tree failed: $e');
      print('⚠️ Attempting recovery from local backup...');

      try {
        final currentTracked = await _listTrackedFiles(_cwd);
        for (final rel in currentTracked) {
          final file = File(p.join(_cwd.path, rel));
          if (file.existsSync()) {
            file.deleteSync();
          }
        }

        if (backupDir.existsSync()) {
          await _copyTrackedFiles(backupDir, _cwd);
          print('✅ Previous working tree recovered from backup.');
        } else {
          print('❌ Recovery backup not found.');
        }
      } catch (recoveryError) {
        print('❌ Recovery failed: $recoveryError');
      }

      rethrow;
    } finally {
      if (tempRestoreDir.existsSync()) {
        tempRestoreDir.deleteSync(recursive: true);
      }
    }
  }

  Future<_GitCheckResult> _checkGitRepository() async {
    final result = await Process.run(
      'git',
      ['rev-parse', '--is-inside-work-tree'],
      workingDirectory: _cwd.path,
    );

    final ok = result.exitCode == 0 &&
        result.stdout.toString().trim().toLowerCase() == 'true';

    return _GitCheckResult(
      ok: ok,
      message: ok ? 'Git repository detected.' : 'Current folder is not a Git repository.',
    );
  }

  Future<bool> _gitWorkingTreeIsClean() async {
    final result = await Process.run(
      'git',
      ['status', '--porcelain'],
      workingDirectory: _cwd.path,
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to read git status: ${result.stderr}');
    }

    return result.stdout.toString().trim().isEmpty;
  }

  Future<bool> _gitBranchExists(String branch) async {
    final result = await Process.run(
      'git',
      ['rev-parse', '--verify', branch],
      workingDirectory: _cwd.path,
    );

    return result.exitCode == 0;
  }

  Future<bool> _gitRemoteExists(String remote) async {
    final result = await Process.run(
      'git',
      ['remote', 'get-url', remote],
      workingDirectory: _cwd.path,
    );

    return result.exitCode == 0;
  }

  Future<void> _gitCheckoutBranch(String branch) async {
    final exists = await _gitBranchExists(branch);

    final result = exists
        ? await Process.run(
            'git',
            ['checkout', branch],
            workingDirectory: _cwd.path,
          )
        : await Process.run(
            'git',
            ['checkout', '-b', branch],
            workingDirectory: _cwd.path,
          );

    if (result.exitCode != 0) {
      throw Exception('Failed to checkout branch "$branch": ${result.stderr}');
    }
  }

  Future<void> _gitAddAll() async {
    final result = await Process.run(
      'git',
      ['add', '-A'],
      workingDirectory: _cwd.path,
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to stage files: ${result.stderr}');
    }
  }

  Future<bool> _gitHasStagedChanges() async {
    final result = await Process.run(
      'git',
      ['diff', '--cached', '--quiet'],
      workingDirectory: _cwd.path,
    );

    if (result.exitCode == 0) return false;
    if (result.exitCode == 1) return true;

    throw Exception('Failed to inspect staged changes: ${result.stderr}');
  }

  Future<void> _gitCommit(String message) async {
    final result = await Process.run(
      'git',
      ['commit', '-m', message],
      workingDirectory: _cwd.path,
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to create git commit: ${result.stderr}');
    }
  }

  Future<void> _gitPush(String remote, String branch) async {
    final result = await Process.run(
      'git',
      ['push', remote, branch],
      workingDirectory: _cwd.path,
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to push branch "$branch" to "$remote": ${result.stderr}');
    }
  }

  String _buildPublishCommitMessage(SnapshotLogEntry entry) {
    final authorPart = (entry.author != null && entry.author!.trim().isNotEmpty)
        ? ' (author: ${entry.author})'
        : '';
    return 'Portable VCS sync ${entry.id}: ${entry.message}$authorPart';
  }

  bool confirmAction(String message) {
    stdout.write('$message (y/N): ');
    return (stdin.readLineSync() ?? '').trim().toLowerCase() == 'y';
  }

}

extension ColorConsole on String {
  String get green => '\x1B[32m$this\x1B[0m';
  String get yellow => '\x1B[33m$this\x1B[0m';
  String get red => '\x1B[31m$this\x1B[0m';
  String get cyan => '\x1B[36m$this\x1B[0m';
}

Future<void> main(List<String> args) async {
  final app = PortableVcs();

  final parser = ArgParser()
    ..addCommand('setup')
    ..addCommand('init')
    ..addCommand('status')
    ..addCommand('log')
    ..addCommand('show')
    ..addCommand('pull')
    ..addCommand('list')
    ..addCommand('doctor')
    ..addCommand('stats')
    ..addCommand('help')
    ..addCommand('clear-history')
    ..addCommand('purge')
    ..addCommand('verify')
    ..addCommand('bind')
    ..addCommand('diff')
    ..addCommand(
      'push',
      ArgParser()..addOption('author', abbr: 'a'),
    )
    ..addCommand('revert')
    ..addCommand(
      'restore',
      ArgParser()..addOption('to'),
    )
    ..addCommand(
      'clone',
      ArgParser()..addOption('into'),
    )
    ..addCommand(
      'prune',
      ArgParser()
        ..addOption('keep')
        ..addOption('older-than'),
    )
    ..addCommand(
      'git-prepare',
      ArgParser()
        ..addOption('branch', defaultsTo: 'main')
        ..addFlag('dry-run', negatable: false),
    )
    ..addCommand(
      'publish',
      ArgParser()
        ..addOption('branch', defaultsTo: 'main')
        ..addOption('remote', defaultsTo: 'origin')
        ..addFlag('dry-run', negatable: false),
    );

  if (args.isEmpty) {
    app.showHelp();
    return;
  }

  try {
    final result = parser.parse(args);
    switch (result.command?.name) {
      case 'setup':
        await app.setupDrive();
        break;
      case 'init':
        await app.init();
        break;
      case 'list':
        await app.listRepos();
        break;
      case 'bind':
        final bindCmd = result.command!;
        final repoId = bindCmd.rest.isNotEmpty ? bindCmd.rest.first : null;
        await app.bindRepo(repoId: repoId);
        break;
      case 'status':
        await app.status();
        break;
      case 'diff':
        await app.diff(result.command?.rest ?? []);
        break;
      case 'log':
        await app.log();
        break;
      case 'show':
        final rest = result.command?.rest ?? [];
        if (rest.isEmpty) {
          print('❌ You must provide a snapshot ID.');
          return;
        }
        await app.showSnapshot(rest.first);
        break;
      case 'doctor':
        await app.doctor();
        break;
      case 'stats':
        await app.stats();
        break;
      case 'pull':
        await app.pull();
        break;
      case 'clear-history':
        await app.clearHistory();
        break;
      case 'purge':
        await app.purge();
        break;
      case 'verify':
        final rest = result.command?.rest ?? [];
        if (rest.isEmpty) {
          print('❌ You must provide a snapshot ID.');
          return;
        }
        await app.verify(rest.first);
        break;
      case 'revert':
        final rest = result.command?.rest ?? [];
        if (rest.isEmpty) {
          print('❌ You must provide a snapshot ID.');
          return;
        }
        await app.revert(rest.first);
        break;
      case 'restore':
        final restoreCmd = result.command!;
        if (restoreCmd.rest.isEmpty) {
          print('❌ You must provide a snapshot ID.');
          return;
        }
        final to = restoreCmd['to']?.toString();
        if (to == null || to.trim().isEmpty) {
          print('❌ You must provide --to <folder>.');
          return;
        }
        await app.restoreTo(restoreCmd.rest.first, to);
        break;
      case 'push':
        final pushCmd = result.command!;
        if (pushCmd.rest.isEmpty) {
          print('❌ You must provide a message.');
          return;
        }
        await app.push(
          pushCmd.rest.join(' '),
          author: pushCmd['author']?.toString(),
        );
        break;
      case 'clone':
        final cloneCmd = result.command!;
        final repoId = cloneCmd.rest.isNotEmpty ? cloneCmd.rest.first : null;
        final into = cloneCmd['into']?.toString();
        await app.cloneRepo(repoId: repoId, into: into);
        break;
      case 'prune':
        final pruneCmd = result.command!;
        final keep = pruneCmd['keep'] != null ? int.tryParse(pruneCmd['keep'].toString()) : null;
        final olderThan = pruneCmd['older-than'] != null
            ? int.tryParse(pruneCmd['older-than'].toString())
            : null;
        await app.prune(keep: keep, olderThanDays: olderThan);
        break;
      case 'git-prepare':
        final cmd = result.command!;
        final snapshotId = cmd.rest.isNotEmpty ? cmd.rest.first : null;
        await app.gitPrepare(
          snapshotId: snapshotId,
          branch: cmd['branch'].toString(),
          dryRun: cmd['dry-run'] == true,
        );
        break;
      case 'publish':
        final cmd = result.command!;
        final snapshotId = cmd.rest.isNotEmpty ? cmd.rest.first : null;
        await app.publish(
          snapshotId: snapshotId,
          branch: cmd['branch'].toString(),
          remote: cmd['remote'].toString(),
          dryRun: cmd['dry-run'] == true,
        );
        break;
      default:
        app.showHelp();
    }
  } catch (e) {
    print('❌ Error: $e');
  }
}

enum _DiffLineType {
  context,
  added,
  removed,
}

class _DiffLine {
  final String text;
  final _DiffLineType type;

  _DiffLine(this.text, this.type);

  factory _DiffLine.context(String text) => _DiffLine(text, _DiffLineType.context);
  factory _DiffLine.added(String text) => _DiffLine(text, _DiffLineType.added);
  factory _DiffLine.removed(String text) => _DiffLine(text, _DiffLineType.removed);
}

class _Range {
  int start;
  int end;

  _Range(this.start, this.end);
}

class _GitCheckResult {
  final bool ok;
  final String message;

  _GitCheckResult({
    required this.ok,
    required this.message,
  });
}
