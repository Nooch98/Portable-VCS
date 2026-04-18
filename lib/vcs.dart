import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' as crypto_alg;
import 'package:path/path.dart' as p;
import 'package:vcs/models/change_counts.dart';
import 'package:vcs/models/decrypted_snapshot.dart';
import 'package:vcs/models/diff_line.dart';
import 'package:vcs/models/file_change.dart';
import 'package:vcs/models/git_check.dart';
import 'package:vcs/models/ignore_rule.dart';
import 'package:vcs/models/range.dart';
import 'package:vcs/models/repo_context.dart';
import 'package:vcs/models/repo_meta.dart';
import 'package:vcs/models/snapshot_log_entry.dart';
import 'package:vcs/models/track_state.dart';
import 'package:vcs/models/tree_node.dart';

const String version = 'Portable VCS Version 0.2.0-Experimental';
enum LogViewMode { summary, standard, full}

class PortableVcs {
  static const String driveMarkerFile = '.vcs_drive';
  static const String localMetaDirName = '.vcs';
  static const String localRepoFileName = 'repo.json';
  static const String remoteReposDir = 'repos';
  static const String remoteMetaFileName = 'meta.json';
  static const String lockFileName = '.lock';
  String? currentWebPassword;

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
    print('\n🚀 ${'PORTABLE SNAPSHOT VAULT'.black.onCyan}');
    print('${'Offline encrypted snapshot tool for Git-compatible local workflows.'.yellow}\n');

    print('${"Usage".cyan}');
    print('  vcs <command> [arguments]\n');

    print('${"Repository setup".cyan}');
    print('  ${'setup'.green.padRight(28)} Prepare a USB drive or external storage for VCS use.');
    print('  ${'init'.green.padRight(28)} Initialize the current project and link it to remote storage.');
    print('  ${'list'.green.padRight(28)} List repositories available on the connected USB/storage.');
    print('  ${'clone [repo_id] [--into dir]'.green.padRight(28)} Clone a repository from USB into a local folder.');
    print('  ${'bind [repo_id]'.green.padRight(28)} Bind the current folder to an existing remote repository.');

    print('\n${"Tracks Management".cyan}');
    print('  ${'track list'.green.padRight(28)} List all available tracks.');
    print('  ${'track current'.green.padRight(28)} Show the name of the active track.');
    print('  ${'track create <name>'.green.padRight(28)} Create a new empty track.');
    print('  ${'track switch <name>'.green.padRight(28)} Switch to another track (Optional tree restore).');
    print('  ${'track delete <name>'.green.padRight(28)} Delete an existing non-active track.');

    print('\n${"Snapshot workflow (Interoperable)".cyan}');
    print('  ${'push "msg" [-a aut] [-t t]'.green.padRight(28)} Create a snapshot (with preview & confirmation).');
    print('  ${'pull [-t name] [id]'.green.padRight(28)} Restore latest or specific snapshot (with preview).');
    print('  ${'revert <id>'.green.padRight(28)} Quick restore of a specific ID from active track.');
    print('  ${'restore <id> --to dir'.green.padRight(28)} Restore a specific snapshot into another folder.');

    print('\n${"Inspection & Web Interface".cyan}');
    print('  ${'ui'.green.padRight(28)} Launch the Web Dashboard (Split-view diff support).');
    print('  ${'status'.green.padRight(28)} Compare tree against latest of the active track.');
    print('  ${'summary'.green.padRight(28)} Show a summary of all messages to help create a Git/GitHub commit.');
    print('  ${'diff [id1] [id2]'.green.padRight(28)} Compare working tree vs latest or two specific IDs.');
    print('  ${'diff -t <track-name1> <track-name2>'.green.padRight(28)} Compare the working tree in the last snapshot of both tracks.');
    print('  ${'log [-t name] | <--full>'.green.padRight(28)} Show history of the active or specific track you can use full parameter to see more details on log.');
    print('  ${'show <id> [-t name]'.green.padRight(28)} Show details of a snapshot (cross-track support).');
    print('  ${'tree [id] [-t name]'.green.padRight(28)} Show visual file tree (cross-track support).');
    print('  ${'verify <id|--all>'.green.padRight(28)} Verify integrity of one or all snapshots.');

    print('\n${"Git integration".cyan}');
    print('  ${'git-prepare [id] --branch b'.green.padRight(28)} Prepare current Git repo from a snapshot.');
    print('  ${'publish [id] --branch b --verify'.green.padRight(28)} Commit and push snapshot to Git safely with a security check using regex to prevent leak of APIs, passwords etc etc.');
    print('  ${'git-diff [id] --branch b'.green.padRight(28)} Compare snapshot against current Git HEAD.');

    print('\n${"Maintenance".cyan}');
    print('  ${'doctor'.green.padRight(28)} Run repository diagnostics and health checks.');
    print('  ${'stats'.green.padRight(28)} Show global repo metrics and track breakdown.');
    print('  ${'prune --keep N'.green.padRight(28)} Keep only the newest N snapshots in the active track.');
    print('  ${'prune --older-than N'.green.padRight(28)} Delete all snapshot older than N.');
    print('  ${'clear-history'.green.padRight(28)} Delete all snapshots for the active track.');
    print('  ${'purge'.green.padRight(28)} Completely delete this repository from USB/storage.');

    print('\n${"General".cyan}');
    print('  ${'help'.green.padRight(28)} Show this help message.');
    print('  ${'version'.green.padRight(28)} Show tool version.');

    print('\n${"Examples".cyan}');
    print('  ${'vcs tree -t Experimental'.green} (View tree of another track)');
    print('  ${'vcs pull -t main'.green} (Preview and pull from main track)');
    print('  ${'vcs show 1713421 -t prod'.green} (Inspect snapshot from production)');

    print('\n${"Notes".cyan}');
    print('  - Commands like ${'push'.yellow}, ${'pull'.yellow}, ${'show'.yellow}, and ${'tree'.yellow} support ${'--track/-t'.yellow}.');
    print('  - ${'push'.green} and ${'pull'.green} now include an automatic ${'safety preview'.yellow} of changes.');
    print('  - Maintenance commands currently target the ${'active track'.yellow} for safety.');
    print('  - All snapshots are ${'AES-256 encrypted'.green} and require the vault password.\n');
  }

  Future<void> setupDrive() async {
    print('\n🔍 ${"SCANNING FOR EXTERNAL DRIVES".black.onCyan}');
    
    final candidates = await _listCandidateDrives();
    if (candidates.isEmpty) {
      print('❌ ${"No candidate drives found.".red}');
      print('   ${"Make sure your USB drive is mounted and has write permissions.".grey}');
      return;
    }

    print('\n${"Select a drive to provision:".bold}');
    print('═' * 60);

    for (var i = 0; i < candidates.length; i++) {
      final drive = candidates[i];
      String sizeInfo = '';
      try {
        final stat = drive.statSync();
        sizeInfo = drive is Directory ? ' (Directory ready)' : '';
      } catch (_) {}

      print('  ${"[$i]".green.bold} ${drive.path.white} $sizeInfo');
    }
    print('═' * 60);

    stdout.write('\n👉 Select index to provision: ');
    final raw = stdin.readLineSync()?.trim() ?? '';
    final index = int.tryParse(raw);
    
    if (index == null || index < 0 || index >= candidates.length) {
      print('❌ ${"Invalid selection.".red}');
      return;
    }

    final selected = candidates[index];

    print('\n${"⚠️  WARNING:".black.onYellow} You are about to provision ${selected.path.bold}');
    print('This will create a hidden marker and the ${remoteReposDir.cyan} directory.');
    stdout.write('Do you want to continue? (y/N): ');
    
    final confirm = stdin.readLineSync()?.trim().toLowerCase();
    if (confirm != 'y' && confirm != 'yes') {
      print('🚫 Setup cancelled.');
      return;
    }

    print('\n⚙️  ${"Provisioning drive...".grey}');

    try {
      await File(p.join(selected.path, driveMarkerFile)).writeAsString(
        'portable-vcs\nversion=1.0\ncreatedAt=${DateTime.now().toIso8601String()}\n',
        flush: true,
      );

      final repoDir = Directory(p.join(selected.path, remoteReposDir));
      if (!repoDir.existsSync()) {
        await repoDir.create(recursive: true);
      }

      print('\n✅ ${"Drive prepared successfully!".green.bold}');
      print('📍 Location: ${selected.path.cyan}');
      print('📦 Repositories will be stored in: ${p.join(selected.path, remoteReposDir).grey}\n');
    } catch (e) {
      print('❌ ${"Failed to provision drive:".red} $e');
    }
  }

  Future<void> init() async {
    print('\n🏗️  ${"INITIALIZING REPOSITORY".black.onCyan}');

    final usb = await findUsbDrive();
    if (usb == null) {
      print('❌ ${"No prepared USB drive found.".red}');
      print('   ${"Please connect your vault drive or run".grey} ${"vcs setup".yellow} ${"first.".grey}');
      return;
    }

    if (_localRepoFile.existsSync()) {
      print('⚠️  ${"This project is already initialized.".yellow}');
      print('   ${"Use".grey} ${"vcs status".cyan} ${"to check the current link.".grey}');
      return;
    }

    final projectName = p.basename(_cwd.path);
    final repoId = _randomId(24);
    final createdAt = DateTime.now().toUtc().toIso8601String();

    print('🔗 ${"Project:".yellow} $projectName');
    print('💾 ${"Target Drive:".yellow} ${usb.path.cyan}');

    try {
      await _localMetaDir.create(recursive: true);

      final localRepoMeta = {
        'repo_id': repoId,
        'project_name': projectName,
        'created_at': createdAt,
        'format_version': 2,
      };

      await _atomicWriteString(
        _localRepoFile,
        const JsonEncoder.withIndent('  ').convert(localRepoMeta),
      );

      final remoteRepoDir = Directory(p.join(usb.path, remoteReposDir, repoId));
      await remoteRepoDir.create(recursive: true);
      await Directory(p.join(remoteRepoDir.path, 'snapshots')).create(recursive: true);

      final defaultTrack = 'main'; 

      final remoteMeta = {
        'repo_id': repoId,
        'project_name': projectName,
        'created_at': createdAt,
        'updated_at': createdAt,
        'format_version': 2,
        'active_track': defaultTrack,
        'tracks': {
          defaultTrack: {
            'logs': [],
          }
        },
      };

      await _atomicWriteString(
        File(p.join(remoteRepoDir.path, remoteMetaFileName)),
        const JsonEncoder.withIndent('  ').convert(remoteMeta),
      );

      print('─' * 60);
      print('✅ ${"Repository initialized successfully!".green.bold}');
      print('${"ID:".yellow.padRight(12)} $repoId');
      print('${"Track:".yellow.padRight(12)} $defaultTrack ${"(default)".grey}');
      print('${"Storage:".yellow.padRight(12)} ${remoteRepoDir.path.grey}');
      print('─' * 60);
      print('💡 ${"Next step:".cyan} Run ${"vcs push \"Initial commit\"".green} to save your first snapshot.\n');

    } catch (e) {
      print('❌ ${"Failed to initialize repository:".red} $e');
      if (_localMetaDir.existsSync()) await _localMetaDir.delete(recursive: true);
    }
  }

  Future<void> listRepos() async {
    final usb = await findUsbDrive();
    if (usb == null) {
      print('\n❌ ${"No prepared USB drive found.".red}');
      print('   ${"Connect your vault or run".grey} ${"vcs setup".yellow}\n');
      return;
    }

    final repos = await _loadRemoteRepos(usb);
    if (repos.isEmpty) {
      print('\nℹ️  ${"No repositories found on USB drive.".yellow}');
      print('   ${"Location:".grey} ${p.join(usb.path, remoteReposDir)}\n');
      return;
    }

    print('\n📦 ${"REMOTE REPOSITORIES IN VAULT".black.onCyan}');
    print('═' * 70);
    
    print('${"ID".padRight(4)} ${"PROJECT NAME".padRight(25)} ${"TRACKS".padRight(10)} ${"LAST UPDATE".padRight(20)}');
    print('─' * 70);

    for (var i = 0; i < repos.length; i++) {
      final repo = repos[i];
      final meta = repo.meta;

      int totalSnapshots = 0;
      meta.tracks.forEach((_, state) => totalSnapshots += state.logs.length);
      
      final trackCount = meta.tracks.length;
      final projectName = meta.projectName.length > 23 
          ? '${meta.projectName.substring(0, 20)}...' 
          : meta.projectName;
      
      final updatedAt = _formatDateForList(meta.updatedAt);
      final isCurrent = _localRepoFile.existsSync() && 
                      (await _readLocalRepoId() == meta.repoId);

      final indexStr = i.toString().padLeft(2, '0').green;
      final rowName = isCurrent ? '$projectName ${"(linked)".magenta}' : projectName.green;

      print('${indexStr.padRight(13)} ${rowName.padRight(34)} ${trackCount.toString().padRight(10)} ${updatedAt.grey}');
      print('     ${"Repo ID:".grey} ${meta.repoId.grey} | ${"Total Snaps:".grey} ${totalSnapshots.toString().grey}');
      
      if (i < repos.length - 1) {
        print('     ' + '┄' * 60);
      }
    }

    print('═' * 70);
    print('${"Total:".grey} ${repos.length} repositories found.');
    print('💡 ${"Use".cyan} ${"vcs clone <repo_id>".green} ${"to download a project.".grey}\n');
  }

  Future<String?> _readLocalRepoId() async {
    try {
      if (!_localRepoFile.existsSync()) return null;
      final content = await _localRepoFile.readAsString();
      final data = jsonDecode(content);
      return data['repo_id'];
    } catch (_) {
      return null;
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

  Future<void> status({String? password}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    print('\n🔍 ${"WORKING TREE STATUS".black.onCyan}');
    print('${"On track:".yellow} ${targetTrackName.magenta.bold}');

    final current = await buildFingerprint(_cwd);

    if (trackData == null || trackData.logs.isEmpty) {
      if (current.isEmpty) {
        print('\n✨ ${"Empty project. Nothing to track.".grey}');
        return;
      }
      print('\n${"Untracked files:".bold}');
      print('  ${"(use \"vcs push <message>\" to create the initial snapshot)".grey}');
      for (final path in current.keys.toList()..sort()) {
        print('    ${'[NEW]'.green} $path');
      }
      return;
    }

    final lastEntry = trackData.logs.first;
    
    final finalPassword = password ?? askPassword();
    if (finalPassword == null) return;

    final snapshot = await readSnapshot(
      context,
      lastEntry.id,
      password: finalPassword,
    );
    
    if (snapshot == null) return;

    final lastFingerprint = Map<String, String>.from(snapshot.fingerprint);
    final changes = diffFingerprints(lastFingerprint, current);

    if (changes.isEmpty) {
      print('\n✨ ${"Working tree clean.".green}');
      print('${"Your project is up to date with the latest snapshot in".grey} ${targetTrackName.cyan}.');
      return;
    }

    print('\n${"Changes not yet pushed:".bold}');
    print('  ${"(use \"vcs push <message>\" to save these changes)".grey}\n');

    int added = 0, modified = 0, deleted = 0;

    for (final change in changes) {
      final tag = change.toTag();
      if (tag.startsWith('+')) {
        print('    ${'[NEW]'.green.padRight(8)} ${change.path}');
        added++;
      } else if (tag.startsWith('-')) {
        print('    ${'[DEL]'.red.padRight(8)} ${change.path}');
        deleted++;
      } else {
        print('    ${'[MOD]'.yellow.padRight(8)} ${change.path}');
        modified++;
      }
    }

    print('\n' + '─' * 40);
    print('${"Summary:".cyan} ${added.toString().green} new, ${modified.toString().yellow} modified, ${deleted.toString().red} deleted.');
    print('─' * 40 + '\n');
  }

  Future<void> diff(List<String> args, {String? password}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final finalPassword = password ?? askPassword();
    if (finalPassword == null || finalPassword.isEmpty) {
      print('❌ Password required for decryption.');
      return;
    }

    late final Map<String, Uint8List> leftFiles;
    late final Map<String, Uint8List> rightFiles;
    late final String leftLabel;
    late final String rightLabel;

    String? resolveId(String input) {
      if (context.remoteMeta.tracks.containsKey(input)) {
        final trackLogs = context.remoteMeta.tracks[input]!.logs;
        if (trackLogs.isEmpty) {
          print('ℹ️ Track "$input" has no snapshots.'.yellow);
          return null;
        }
        return trackLogs.first.id;
      }
      return input;
    }

    try {
      if (args.isEmpty) {
        if (context.remoteMeta.logs.isEmpty) {
          print('ℹ️ No snapshots available in active track.'.yellow);
          return;
        }
        final latestId = context.remoteMeta.logs.first.id;
        final snapshot = await readSnapshot(context, latestId, password: finalPassword);
        if (snapshot == null) return;

        leftFiles = await _decodeSnapshotFiles(snapshot);
        rightFiles = await _readCurrentProjectFiles();
        leftLabel = 'snapshot:$latestId (latest)';
        rightLabel = 'working-tree';
      } 
      else if (args.length == 1) {
        final id = resolveId(args[0]);
        if (id == null) return;

        final snapshot = await readSnapshot(context, id, password: finalPassword);
        if (snapshot == null) return;

        leftFiles = await _decodeSnapshotFiles(snapshot);
        rightFiles = await _readCurrentProjectFiles();
        leftLabel = 'snapshot:$id';
        rightLabel = 'working-tree';
      } 
      else if (args.length == 2) {
        final idLeft = resolveId(args[0]);
        final idRight = resolveId(args[1]);
        if (idLeft == null || idRight == null) return;

        final leftSnapshot = await readSnapshot(context, idLeft, password: finalPassword);
        if (leftSnapshot == null) return;

        final rightSnapshot = await readSnapshot(context, idRight, password: finalPassword);
        if (rightSnapshot == null) return;

        leftFiles = await _decodeSnapshotFiles(leftSnapshot);
        rightFiles = await _decodeSnapshotFiles(rightSnapshot);
        leftLabel = 'snapshot:$idLeft';
        rightLabel = 'snapshot:$idRight';
      } 
      else {
        print('❌ Usage: vcs diff [track_or_id_1] [track_or_id_2]'.red);
        return;
      }

      await _printDiffBetweenFileMaps(
        leftFiles,
        rightFiles,
        leftLabel: leftLabel,
        rightLabel: rightLabel,
      );
    } catch (e) {
      print('❌ Error during diff: $e');
    }
  }

  Future<void> push(String message, {String? author, String? track, String? password}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    if (trackData == null) {
      print('❌ Track "$targetTrackName" does not exist.');
      return;
    }

    final finalPassword = password ?? askPassword();
    if (finalPassword == null || finalPassword.isEmpty) {
      print('❌ Password required for encryption.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      final currentFingerprint = await buildFingerprint(_cwd);

      Map<String, String> lastFingerprint = {};
      if (trackData.logs.isNotEmpty) {
        final lastEntry = trackData.logs.first;
        
        try {
          final lastSnapshot = await readSnapshot(
            context,
            lastEntry.id,
            password: finalPassword,
          );
          
          if (lastSnapshot != null) {
            lastFingerprint = Map<String, String>.from(lastSnapshot.fingerprint);
          }
        } catch (e) {
          print('⚠️ Warning: Error reading previous snapshot. Comparing against empty state.');
        }
      }

      final changes = diffFingerprints(lastFingerprint, currentFingerprint);

      if (changes.isEmpty && trackData.logs.isNotEmpty) {
        print('ℹ️ No changes to save in track "$targetTrackName".');
        return;
      }

      print('\n${'--- Snapshot Preview ---'.cyan}');
      print('${'Track:'.padRight(12)} $targetTrackName');
      print('${'Message:'.padRight(12)} $message');
      if (author != null) print('${'Author:'.padRight(12)} $author');
      print('');

      int added = 0, modified = 0, deleted = 0;

      for (var change in changes) {
        final tag = change.toTag();
        String prefix = '';
        
        if (tag.startsWith('+')) {
          prefix = '[+]'.green;
          added++;
        } else if (tag.startsWith('-')) {
          prefix = '[-]'.red;
          deleted++;
        } else {
          prefix = '[~]'.yellow;
          modified++;
        }
        
        print('  $prefix ${change.path}');
      }

      print('\nSummary: ${added.toString().green} added, ${modified.toString().yellow} modified, ${deleted.toString().red} deleted.');
      
      stdout.write('\nDo you want to proceed with the push? (y/N): ');
      String? confirm = stdin.readLineSync()?.trim().toLowerCase();
      if (confirm != 'y' && confirm != 'yes') {
        print('🚫 Push aborted by user.');
        return;
      }

      print('📦 Packing and encrypting...');
      final zipBytes = await _createZipFromCurrentProject();
      final encrypted = await _encryptSnapshot(
        zipBytes: zipBytes,
        message: message,
        author: author,
        fingerprint: currentFingerprint,
        password: finalPassword,
      );

      final snapshotId = DateTime.now().millisecondsSinceEpoch.toString();
      final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
      if (!snapshotsDir.existsSync()) await snapshotsDir.create(recursive: true);

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

      final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
      updatedTracks[targetTrackName] = TrackState(
        logs: [entry, ...trackData.logs],
      );

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        tracks: updatedTracks,
      );

      await _atomicWriteString(
        File(p.join(context.remoteRepoDir.path, remoteMetaFileName)),
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
      );

      print('✅ Snapshot saved successfully in track ${targetTrackName.cyan}. ID=$snapshotId');
    });
  }

  Future<void> log({LogViewMode mode = LogViewMode.summary, String? track}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    if (trackData == null) {
      print('❌ Track "$targetTrackName" not found.');
      return;
    }

    if (trackData.logs.isEmpty) {
      print('ℹ️ ${"No snapshots in track $targetTrackName.".yellow}');
      return;
    }

    print('\n📜 ${"Snapshot history".cyan} [Track: ${targetTrackName.cyan}]');
    print('═' * 60);

    final logs = trackData.logs.reversed.toList();

    for (var i = 0; i < logs.length; i++) {
      final entry = logs[i];
      final createdAt = _formatDateForList(entry.createdAt);
      final author = entry.author ?? '-';
      final isLatest = i == logs.length - 1;

      final counts = countChanges(entry.changeSummary);

      print(
        '[${i.toString().padLeft(2, '0')}] '
        '${entry.id.green}'
        '${isLatest ? " ${"(latest)".cyan}" : ""}',
      );

      print('     ${"Date:".yellow.padRight(10)} $createdAt');
      print('     ${"Author:".yellow.padRight(10)} $author');
      print('     ${"Message:".yellow.padRight(10)} ${entry.message.cyan}');

      switch (mode) {
        case LogViewMode.summary:
          if (entry.changeSummary.isEmpty) {
            print('     ${"Changes:".yellow.padRight(10)} ${"(none)".red}');
          } else {
            print(
              '     ${"Changes:".yellow.padRight(10)} '
              '${counts.total.toString().green} file(s) '
              '(${'+${counts.added}'.green} ${'~${counts.modified}'.yellow} ${'-${counts.deleted}'.red})',
            );
          }
          break;

        case LogViewMode.standard:
          if (entry.changeSummary.isEmpty) {
            print('     ${"Changes:".yellow.padRight(10)} ${"(none)".red}');
          } else {
            print(
              '     ${"Changes:".yellow.padRight(10)} '
              '${counts.total.toString().green} file(s) '
              '(${'+${counts.added}'.green} ${'~${counts.modified}'.yellow} ${'-${counts.deleted}'.red})',
            );

            final preview = entry.changeSummary.take(5).toList();
            for (final c in preview) {
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

            final remaining = entry.changeSummary.length - preview.length;
            if (remaining > 0) {
              print('       ${"... and $remaining more change(s)".yellow}');
            }
          }
          break;

        case LogViewMode.full:
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
          break;
      }

      if (i != logs.length - 1) {
        print('─' * 60);
      }
    }

    print('═' * 60);
  }

  ChangeCounts countChanges(List<String> changes) {
    var added = 0;
    var modified = 0;
    var deleted = 0;

    for (final c in changes) {
      if (c.startsWith('[N]')) {
        added++;
      } else if (c.startsWith('[M]')) {
        modified++;
      } else if (c.startsWith('[D]')) {
        deleted++;
      }
    }

    return ChangeCounts(
      added: added,
      modified: modified,
      deleted: deleted,
    );
  }

  Future<void> showSnapshot(String snapshotId, {String? track}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    if (trackData == null) {
      print('❌ ${"Track not found:".red} $targetTrackName');
      return;
    }

    SnapshotLogEntry? entry;
    for (final item in trackData.logs) {
      if (item.id == snapshotId) {
        entry = item;
        break;
      }
    }

    if (entry == null) {
      print('❌ ${"Snapshot not found in track".red} ${targetTrackName.cyan}: $snapshotId');
      return;
    }

    final file = File(p.join(context.remoteRepoDir.path, 'snapshots', entry.fileName));
    final size = file.existsSync() ? file.lengthSync() : 0;

    final createdAt = _formatDateForList(entry.createdAt);
    final author = entry.author ?? '-';

    print('\n🔎 ${"Snapshot details".cyan}');
    print('═' * 60);

    print('${"ID:".yellow.padRight(12)} ${entry.id.green}');
    print('${"Track:".yellow.padRight(12)} ${targetTrackName.cyan}');
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

  Future<void> verify({
    String? snapshotId,
    bool verifyAll = false,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final password = askPassword();
    if (password == null) return;

    if (verifyAll) {
      await _verifyAllSnapshots(context, password);
      return;
    }

    if (snapshotId == null || snapshotId.trim().isEmpty) {
      print('❌ ${"Usage: vcs verify <snapshot_id> OR vcs verify --all".red}');
      return;
    }

    final snapshot = await readSnapshot(
      context,
      snapshotId,
      password: password,
    );

    if (snapshot == null) return;

    try {
      ZipDecoder().decodeBytes(snapshot.zipBytes, verify: true);
      print('✅ ${"Snapshot is valid and decryptable.".green}');
    } catch (e) {
      print('❌ ${"Snapshot verification failed:".red} $e');
    }
  }

  Future<void> _verifyAllSnapshots(
    RepoContext context,
    String password,
  ) async {
    final logs = context.remoteMeta.logs;
    final snapshotsDir = Directory(
      p.join(context.remoteRepoDir.path, 'snapshots'),
    );

    print('\n🔍 ${"Verifying all snapshots...".cyan}');
    print('═' * 60);

    int valid = 0;
    int failed = 0;

    final expectedFiles = <String>{};

    for (final entry in logs) {
      expectedFiles.add(entry.fileName);

      final file = File(
        p.join(snapshotsDir.path, entry.fileName),
      );

      if (!file.existsSync()) {
        failed++;
        print('${"[FAIL]".red} ${entry.id.yellow} -> missing file');
        continue;
      }

      try {
        final snapshot = await readSnapshot(
          context,
          entry.id,
          password: password,
        );

        if (snapshot == null) {
          failed++;
          print('${"[FAIL]".red} ${entry.id.yellow} -> cannot decrypt');
          continue;
        }

        ZipDecoder().decodeBytes(snapshot.zipBytes, verify: true);

        valid++;
        print('${"[OK]".green} ${entry.id.green}');
      } catch (e) {
        failed++;
        print('${"[FAIL]".red} ${entry.id.yellow} -> $e');
      }
    }

    final orphanFiles = <String>[];

    if (snapshotsDir.existsSync()) {
      for (final entity in snapshotsDir.listSync()) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (!expectedFiles.contains(name)) {
            orphanFiles.add(name);
          }
        }
      }
    }

    print('═' * 60);
    print('${"Snapshots checked:".yellow.padRight(20)} ${logs.length}');
    print('${"Valid:".yellow.padRight(20)} ${valid.toString().green}');
    print('${"Failed:".yellow.padRight(20)} ${failed.toString().red}');
    print('${"Orphan files:".yellow.padRight(20)} ${orphanFiles.length.toString().yellow}');

    if (orphanFiles.isNotEmpty) {
      print('\n🗂️ ${"Orphan snapshot files:".yellow}');
      for (final orphan in orphanFiles) {
        print('  ${orphan.yellow}');
      }
    }

    if (failed == 0) {
      print('\n✅ ${"Repository verification complete.".green}');
    } else {
      print('\n⚠️ ${"Repository verification completed with errors.".yellow}');
    }

    print('');
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
    
    // Consolidar todos los logs de todos los tracks para métricas globales
    final allLogs = <SnapshotLogEntry>[];
    context.remoteMeta.tracks.forEach((name, state) {
      allLogs.addAll(state.logs);
    });

    int totalBytes = 0;
    int largestBytes = 0;
    String? largestId;
    String? largestTrack;

    if (snapshotsDir.existsSync()) {
      // Buscamos en los archivos físicos basados en todos los tracks
      for (var trackEntry in context.remoteMeta.tracks.entries) {
        for (final entry in trackEntry.value.logs) {
          final file = File(p.join(snapshotsDir.path, entry.fileName));
          if (!file.existsSync()) continue;

          final size = file.lengthSync();
          totalBytes += size;

          if (size > largestBytes) {
            largestBytes = size;
            largestId = entry.id;
            largestTrack = trackEntry.key;
          }
        }
      }
    }

    print('\n📊 ${"REPOSITORY STATISTICS".black.onCyan}');
    print('═' * 60);

    // --- Sección 1: Información General ---
    print('${"GENERAL INFO".bold.cyan}');
    print('${"Project Name:".yellow.padRight(20)} ${context.remoteMeta.projectName.green}');
    print('${"Active Track:".yellow.padRight(20)} ${context.remoteMeta.activeTrack.magenta.bold}');
    print('${"Total Tracks:".yellow.padRight(20)} ${context.remoteMeta.tracks.length.toString().white}');
    print('${"Format Version:".yellow.padRight(20)} v${context.remoteMeta.formatVersion}');
    print('${"Vault Location:".yellow.padRight(20)} ${context.remoteRepoDir.path.grey}');

    print('\n${"STORAGE SUMMARY".bold.cyan}');
    // --- Sección 2: Métricas de Almacenamiento ---
    print('${"Total Snapshots:".yellow.padRight(20)} ${allLogs.length.toString().green}');
    print('${"Vault Total Size:".yellow.padRight(20)} ${_formatBytes(totalBytes).green.bold}');
    
    if (allLogs.isNotEmpty) {
      final avgSize = totalBytes ~/ allLogs.length;
      print('${"Average Size:".yellow.padRight(20)} ${_formatBytes(avgSize).white}');
      print(
        '${"Largest Item:".yellow.padRight(20)} '
        '${largestId?.green ?? "N/A"} '
        '(${_formatBytes(largestBytes)}) ${'in'.grey} ${largestTrack?.magenta ?? ""}'
      );
    }

    print('\n${"TRACKS BREAKDOWN".bold.cyan}');
    // --- Sección 3: Desglose por Tracks ---
    context.remoteMeta.tracks.forEach((name, state) {
      final isActive = name == context.remoteMeta.activeTrack;
      final prefix = isActive ? ' → '.cyan.bold : '   ';
      final count = state.logs.length;
      print('$prefix${name.padRight(17)} ${count.toString().padLeft(3)} snapshots');
    });

    print('\n${"TIMELINE".bold.cyan}');
    // --- Sección 4: Fechas ---
    if (allLogs.isNotEmpty) {
      // Ordenamos por fecha para obtener el más nuevo y más viejo real
      allLogs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final newest = allLogs.first;
      final oldest = allLogs.last;

      print('${"Newest Snapshot:".yellow.padRight(20)} ${newest.id.green} (${_formatDateForList(newest.createdAt)})');
      print('${"Oldest Snapshot:".yellow.padRight(20)} ${oldest.id.green} (${_formatDateForList(oldest.createdAt)})');
    }

    print('═' * 60);
    print('${"Last sync:".grey} ${_formatDateForList(context.remoteMeta.updatedAt)}');
    print('');
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
    final toDeleteIds = <String>{};

    if (olderThanDays != null) {
      for (final entry in logs) {
        final created = DateTime.tryParse(entry.createdAt)?.toUtc();
        if (created == null) continue;

        final age = now.difference(created).inDays;
        if (age > olderThanDays) {
          toDeleteIds.add(entry.id);
        }
      }
    }

    if (keep != null && keep >= 0 && logs.length > keep) {
      for (var i = keep; i < logs.length; i++) {
        toDeleteIds.add(logs[i].id);
      }
    }

    if (toDeleteIds.length >= logs.length && logs.isNotEmpty) {
      toDeleteIds.remove(logs.first.id);
    }

    if (toDeleteIds.isEmpty) {
      print('ℹ️ Nothing to prune.');
      return;
    }

    final toDelete = logs.where((e) => toDeleteIds.contains(e.id)).toList();

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
        final file = File(
          p.join(context.remoteRepoDir.path, 'snapshots', entry.fileName),
        );
        if (file.existsSync()) {
          file.deleteSync();
        }
      }

      final remaining = logs.where((e) => !toDeleteIds.contains(e.id)).toList();

      final updatedTracks = Map<String, TrackState>.from(
        context.remoteMeta.tracks,
      );

      updatedTracks[context.remoteMeta.activeTrack] = TrackState(
        logs: remaining,
      );

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        tracks: updatedTracks,
      );

      await _atomicWriteString(
        File(p.join(context.remoteRepoDir.path, remoteMetaFileName)),
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
      );

      print('✅ Pruned ${toDelete.length} snapshots.');
      print('ℹ️ Remaining snapshots in track "${context.remoteMeta.activeTrack}": ${remaining.length}');
    });
  }

  Future<void> pull({String? track, String? snapshotId, String? password}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    if (trackData == null) {
      print('❌ Track "$targetTrackName" not found.');
      return;
    }

    if (trackData.logs.isEmpty) {
      print('ℹ️ No snapshots available in track "$targetTrackName".');
      return;
    }

    final finalSnapshotId = snapshotId ?? trackData.logs.first.id;
    final entry = trackData.logs.firstWhere(
      (e) => e.id == finalSnapshotId,
      orElse: () => SnapshotLogEntry(id: '', message: '', createdAt: '', fileName: '', author: '', changeSummary: []),
    );

    if (entry.id.isEmpty) {
      print('❌ Snapshot ID "$finalSnapshotId" not found in track "$targetTrackName".');
      return;
    }

    print('\n${'--- Pull/Restore Preview ---'.cyan}');
    print('${'Source Track:'.padRight(15)} $targetTrackName');
    print('${'Snapshot ID:'.padRight(15)} ${entry.id.green}');
    print('${'Message:'.padRight(15)} ${entry.message.yellow}');
    print('${'Author:'.padRight(15)} ${entry.author ?? 'Unknown'}');
    print('');

    if (entry.changeSummary.isEmpty) {
      print('  ${"(No file changes recorded in this snapshot)".yellow}');
    } else {
      for (final c in entry.changeSummary) {
        if (c.startsWith('[N]')) {
          print('  ${'[+]'.green} ${c.substring(3).trim()}');
        } else if (c.startsWith('[M]')) {
          print('  ${'[~]'.yellow} ${c.substring(3).trim()}');
        } else if (c.startsWith('[D]')) {
          print('  ${'[-]'.red} ${c.substring(3).trim()}');
        } else {
          print('  $c');
        }
      }
    }

    print('\n${'⚠️ WARNING:'.red} This operation will overwrite your current working directory.');
    stdout.write('Do you want to proceed with the pull? (y/N): ');
    String? confirm = stdin.readLineSync()?.trim().toLowerCase();
    
    if (confirm != 'y' && confirm != 'yes') {
      print('🚫 Pull aborted by user.');
      return;
    }

    final finalPassword = password ?? askPassword();
    if (finalPassword == null || finalPassword.isEmpty) {
      print('❌ Password required for decryption.');
      return;
    }

    print('📥 Pulling snapshot ${finalSnapshotId.green} from track ${targetTrackName.cyan}...');
    await revertWithPassword(finalSnapshotId, finalPassword);
  }

  Future<void> revert(String snapshotId, {String? password}) async {
    final finalPassword = password ?? askPassword();
    if (finalPassword == null) return;

    await revertWithPassword(snapshotId, finalPassword);
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

      final updatedTracks = Map<String, TrackState>.from(
        context.remoteMeta.tracks,
      );

      updatedTracks[context.remoteMeta.activeTrack] = TrackState(
        logs: [],
      );

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        tracks: updatedTracks,
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

    print('\n${'🔥 DANGER ZONE: PURGE REPOSITORY'.black.onRed}');
    print('${'Project:'.yellow} ${context.remoteMeta.projectName}');
    print('${'Repo ID:'.yellow} ${context.remoteMeta.repoId}');
    print('\n${'This will permanently delete:'.red}');
    print('  1. The entire remote vault on the USB drive.');
    print('  2. The local ${'.vcs/'.cyan} metadata folder in this project.');
    
    stdout.write('\n⚠️ Are you absolutely sure? (y/N): ');
    final confirm = (stdin.readLineSync() ?? '').trim().toLowerCase();
    
    if (confirm != 'y' && confirm != 'yes') {
      print('🚫 Purge cancelled.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      try {
        if (context.remoteRepoDir.existsSync()) {
          context.remoteRepoDir.deleteSync(recursive: true);
          print('💀 ${'Remote repo deleted from USB.'.green}');
        }
      } catch (e) {
        print('❌ ${'Error deleting remote repo:'.red} $e');
      }
    });

    try {
      if (_localMetaDir.existsSync()) {
        _localMetaDir.deleteSync(recursive: true);
        print('🗑️  ${'Local .vcs folder removed.'.green}');
      }
    } catch (e) {
      print('❌ ${'Error deleting local metadata:'.red} $e');
    }

    print('\n✨ ${"Purge complete. The project is no longer linked to the vault.".bold}\n');
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

  bool _filesDiffer(Uint8List a, Uint8List b) {
    if (_bytesEqual(a, b)) {
      return false;
    }

    final aText = _normalizeUtf8BytesForComparison(a);
    final bText = _normalizeUtf8BytesForComparison(b);

    if (aText != null && bText != null) {
      return aText != bText;
    }

    return true;
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

      if (_filesDiffer(a, b)) {
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

        final aText = _normalizeUtf8BytesForComparison(a);
        final bText = _normalizeUtf8BytesForComparison(b);

        if (aText == null || bText == null) {
          print('  ${"(binary or non-UTF8 content changed)".yellow}');
          print('');
          continue;
        }

        final lines = _simpleLineDiff(aText, bText);

        if (lines.isEmpty) {
          final normalizedA = aText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
          final normalizedB = bText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

          if (normalizedA == normalizedB) {
            print('  ${"(line-ending or encoding-only change)".yellow}');
          } else {
            print('  ${"(content changed, but no line diff available)".yellow}');
          }
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

  List<DiffLine> _buildRawDiffLines(List<String> left, List<String> right) {
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

    final output = <DiffLine>[];
    var i = 0;
    var j = 0;

    while (i < left.length && j < right.length) {
      if (left[i] == right[j]) {
        output.add(DiffLine.context(left[i]));
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        output.add(DiffLine.removed(left[i]));
        i++;
      } else {
        output.add(DiffLine.added(right[j]));
        j++;
      }
    }

    while (i < left.length) {
      output.add(DiffLine.removed(left[i]));
      i++;
    }

    while (j < right.length) {
      output.add(DiffLine.added(right[j]));
      j++;
    }

    return output;
  }

  List<String> _compressDiffIntoBlocks(List<DiffLine> lines, {int context = 2}) {
    if (lines.isEmpty) return [];

    final changeIndexes = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].type != DiffLineType.context) {
        changeIndexes.add(i);
      }
    }

    if (changeIndexes.isEmpty) {
      return [];
    }

    final ranges = <Range>[];

    for (final index in changeIndexes) {
      final start = max(0, index - context);
      final end = min(lines.length - 1, index + context);

      if (ranges.isEmpty) {
        ranges.add(Range(start, end));
        continue;
      }

      final last = ranges.last;
      if (start <= last.end + 1) {
        last.end = max(last.end, end);
      } else {
        ranges.add(Range(start, end));
      }
    }

    final output = <String>[];

    for (var i = 0; i < ranges.length; i++) {
      final range = ranges[i];

      for (var j = range.start; j <= range.end; j++) {
        final line = lines[j];
        switch (line.type) {
          case DiffLineType.context:
            output.add('  ${line.text}');
            break;
          case DiffLineType.added:
            output.add('+ ${line.text}');
            break;
          case DiffLineType.removed:
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
    bool silent = false,
  }) async {
    SnapshotLogEntry? entry;

    for (final track in remoteMeta.tracks.values) {
      for (final item in track.logs) {
        if (item.id == snapshotId) {
          entry = item;
          break;
        }
      }
      if (entry != null) break;
    }

    if (entry == null) {
      if (!silent) print('❌ Snapshot ID not found: $snapshotId');
      return null;
    }

    final file = File(p.join(remoteRepoDir.path, 'snapshots', entry.fileName));
    if (!file.existsSync()) {
      if (!silent) print('❌ Snapshot file is missing: ${entry.fileName}');
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
      if (!silent) print('❌ Wrong password or tampered snapshot.');
      return null;
    } catch (e) {
      if (!silent) print('❌ Could not read snapshot: $e');
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
    if (currentWebPassword != null && currentWebPassword!.isNotEmpty) {
      return currentWebPassword;
    }

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
    bool verify = true,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final gitCheck = await _checkGitRepository();
    if (!gitCheck.ok) {
      print('❌ ${gitCheck.message}');
      return;
    }

    final remoteExists = await _gitRemoteExists(remote);
    if (!remoteExists) {
      print('ℹ️ ${'Notice:'.yellow} Remote "$remote" not found. The snapshot will be committed locally but not pushed.');
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
    print('${"Remote:".yellow.padRight(14)} ${remoteExists ? remote.green : "None (local only)".yellow}');
    print('${"Branch exists:".yellow.padRight(14)} ${branchExists ? "yes".green : "no".yellow}');
    print('${"Commit message:".yellow.padRight(14)} $commitMessage');
    print('${"Mode:".yellow.padRight(14)} ${dryRun ? "dry-run".yellow : "publish".green}');
    print('${"Hooks:".yellow.padRight(14)} ${verify ? "active".green : "disabled".red}');
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

    if (verify) {
      print('\n🛡️  ${"Running security hooks...".cyan}');
      final issues = await _runSecurityScanner();
      if (issues.isNotEmpty) {
        print('\n🚨 ${"Critical issues found during pre-publish scan:".red}');
        for (var issue in issues) {
          print('   ⚠️ $issue');
        }
        print('\n${"Publish aborted for safety.".red}');
        print('ℹ️  Fix the issues above or use --no-verify to bypass.');
        return; 
      }
      print('✅ ${"Security check passed.".green}\n');
    }

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

    if (remoteExists) {
      if (!confirmAction('Push commit to "$remote/$branch" now?')) {
        print('ℹ️ Commit created locally. Push skipped by user.');
        return;
      }
      await _gitPush(remote, branch);
      print('✅ Snapshot ${entry.id} published and pushed to Git.');
    } else {
      print('✅ Snapshot ${entry.id} published to local Git (no remote configured).');
    }
  }

  Future<List<String>> _runSecurityScanner() async {
    final List<String> issues = [];
    final directory = Directory.current;

    final Map<String, RegExp> rules = {
      "Google API Key": RegExp(r"""AIza[0-9A-Za-z-_]{35}"""),
      "OpenAI API Key": RegExp(r"""sk-[a-zA-Z0-9]{48}"""),
      "Generic Secret": RegExp(
        r"""(password|secret|passwd|aws_key|access_token|api_key)\s*[:=]\s*['"].{8,}['"]""",
        caseSensitive: false,
      ),
      "Private Key Header": RegExp(r"""-----BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE KEY-----"""),
      "GitHub Token": RegExp(r"""ghp_[a-zA-Z0-9]{36}"""),
    };

    final ignoredPaths = ['.git', '.vcs', '.dart_tool', 'node_modules', 'build', 'bin', 'obj'];

    try {
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final isIgnored = ignoredPaths.any((p) => entity.path.contains('${Platform.pathSeparator}$p${Platform.pathSeparator}'));
          final isBinary = entity.path.endsWith('.exe') || entity.path.endsWith('.dll') || entity.path.endsWith('.so');

          if (isIgnored || isBinary) continue;

          try {
            final lines = await entity.readAsLines();
            for (var i = 0; i < lines.length; i++) {
              final line = lines[i];
              
              rules.forEach((name, regex) {
                if (regex.hasMatch(line)) {
                  issues.add('$name detected in ${entity.path} (Line ${i + 1})');
                }
              });
            }
          } catch (e) {
            continue;
          }
        }
      }
    } catch (e) {
      print('⚠️ Error during security scan: $e'.yellow);
    }

    return issues;
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

  Future<GitCheckResult> _checkGitRepository() async {
    final result = await Process.run(
      'git',
      ['rev-parse', '--is-inside-work-tree'],
      workingDirectory: _cwd.path,
    );

    final ok = result.exitCode == 0 &&
        result.stdout.toString().trim().toLowerCase() == 'true';

    return GitCheckResult(
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

  Future<void> _gitCommit(String message, {String? snapshotId, String? track}) async {
    final fullMessage = StringBuffer()
      ..writeln(message)
      ..writeln()
      ..writeln('---')
      ..writeln('VCS-Snapshot: ${snapshotId ?? "N/A"}')
      ..writeln('VCS-Track: ${track ?? "N/A"}')
      ..writeln('VCS-Sync-Date: ${DateTime.now().toUtc().toIso8601String()}');

    final result = await Process.run(
      'git',
      ['commit', '-m', fullMessage.toString()],
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

  Future<void> tree([String? snapshotId, String? track]) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    if (trackData == null) {
      print('❌ ${"Track not found:".red} $targetTrackName');
      return;
    }

    if (trackData.logs.isEmpty) {
      print('ℹ️ ${"No snapshots available in track".yellow} ${targetTrackName.cyan}.');
      return;
    }

    final targetId = snapshotId ?? trackData.logs.first.id;
    final entry = trackData.logs.firstWhere(
      (e) => e.id == targetId,
      orElse: () => SnapshotLogEntry(id: '', message: '', createdAt: '', fileName: '', author: '', changeSummary: []),
    );

    if (entry.id.isEmpty) {
      print('❌ ${"Snapshot not found in track".red} ${targetTrackName.cyan}: $targetId');
      return;
    }

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshot(context, targetId, password: password);
    if (snapshot == null) return;

    final files = await _decodeSnapshotFiles(snapshot);
    final paths = files.keys.toList()..sort();

    final treeStats = TreeStats();

    print('\n🌳 ${"SNAPSHOT FILE TREE".black.onCyan}');
    print('═' * 60);
    print('${"Snapshot:".yellow.padRight(12)} ${entry.id.green} (${entry.message.grey})');
    print('${"Track:".yellow.padRight(12)} ${targetTrackName.magenta.bold}');
    print('${"Created:".yellow.padRight(12)} ${_formatDateForList(entry.createdAt)}');
    print('═' * 60);

    if (paths.isEmpty) {
      print('  ${"(Empty snapshot)".grey}');
    } else {
      final root = _buildTree(paths);
      print('${context.remoteMeta.projectName.blue.bold}/'); 

      _printTreeNode(root, prefix: '', stats: treeStats);
    }

    print('─' * 60);
    print('${"Summary:".cyan} ${treeStats.directories.toString().yellow} directories, ${treeStats.files.toString().green} files');
    print('═' * 60 + '\n');
  }

  TreeNode _buildTree(List<String> paths) {
    final root = TreeNode('');

    for (final rawPath in paths) {
      final normalized = rawPath.replaceAll('\\', '/');
      final parts = normalized.split('/');

      var current = root;
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final isFile = i == parts.length - 1;

        current.children.putIfAbsent(
          part,
          () => TreeNode(part, isFile: isFile),
        );

        final next = current.children[part]!;
        if (!isFile) {
          next.isFile = false;
        }

        current = next;
      }
    }

    return root;
  }

  void _printTreeNode(
    TreeNode node, {
    required String prefix,
    required TreeStats stats,
  }) {
    final entries = node.children.values.toList()
      ..sort((a, b) {
        if (a.isFile != b.isFile) {
          return a.isFile ? 1 : -1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    for (var i = 0; i < entries.length; i++) {
      final child = entries[i];
      final isLast = i == entries.length - 1;
      final branch = isLast ? '└── ' : '├── ';

      if (child.isFile) {
        stats.files++;
        String icon = '📄';
        if (child.name.endsWith('.dart')) icon = '🎯';
        if (child.name.endsWith('.json') || child.name.endsWith('.yaml')) icon = '⚙️';
        if (child.name.endsWith('.md')) icon = '📝';
        
        print('$prefix$branch$icon ${child.name.green}');
      } else {
        stats.directories++;
        print('$prefix$branch📁 ${child.name.cyan.bold}/');
        _printTreeNode(
          child,
          prefix: '$prefix${isLast ? '    ' : '│   '}',
          stats: stats,
        );
      }
    }
  }

  Future<void> gitDiff({
    String? snapshotId,
    required String branch,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final gitCheck = await _checkGitRepository();
    if (!gitCheck.ok) {
      print('❌ ${gitCheck.message}'.red);
      return;
    }

    final branchExists = await _gitBranchExists(branch);
    if (!branchExists) {
      print('❌ ${'Git branch not found:'.red} $branch');
      return;
    }

    if (context.remoteMeta.logs.isEmpty) {
      print('ℹ️ ${"No snapshots available.".yellow}');
      return;
    }

    final targetId = snapshotId ?? context.remoteMeta.logs.first.id;

    SnapshotLogEntry? entry;
    for (final item in context.remoteMeta.logs) {
      if (item.id == targetId) {
        entry = item;
        break;
      }
    }

    if (entry == null) {
      print('❌ ${"Snapshot not found:".red} $targetId');
      return;
    }

    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshot(context, targetId, password: password);
    if (snapshot == null) return;

    final snapshotFiles = await _decodeSnapshotFiles(snapshot);
    final gitFiles = await _readGitTreeFiles(branch);

    await _printDiffBetweenFileMaps(
      gitFiles,
      snapshotFiles,
      leftLabel: 'git:$branch@HEAD',
      rightLabel: 'vcs:snapshot:${entry.id}',
    );
  }

  Future<Map<String, Uint8List>> _readGitTreeFiles(String branch) async {
    final files = <String, Uint8List>{};

    final listResult = await Process.run(
      'git',
      ['ls-tree', '-r', '--name-only', branch],
      workingDirectory: _cwd.path,
    );

    if (listResult.exitCode != 0) {
      throw Exception('Failed to list files for branch "$branch": ${listResult.stderr}');
    }

    final output = listResult.stdout.toString().trim();
    if (output.isEmpty) {
      return files;
    }

    final paths = const LineSplitter()
        .convert(output)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();

    for (final path in paths) {
      final normalizedPath = path.replaceAll('\\', '/');

      if (await _isIgnoredPath(normalizedPath)) {
        continue;
      }

      final showResult = await Process.run(
        'git',
        ['show', '$branch:$path'],
        workingDirectory: _cwd.path,
        stdoutEncoding: null,
        stderrEncoding: utf8,
      );

      if (showResult.exitCode != 0) {
        throw Exception('Failed to read "$path" from branch "$branch": ${showResult.stderr}');
      }

      final stdoutValue = showResult.stdout;

      if (stdoutValue is Uint8List) {
        files[normalizedPath] = stdoutValue;
      } else if (stdoutValue is List<int>) {
        files[normalizedPath] = Uint8List.fromList(stdoutValue);
      } else {
        throw Exception('Unexpected git blob output type for "$path".');
      }
    }
    return files;
  }

  String _normalizeTextForComparison(String text) {
    var normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.isNotEmpty && normalized.codeUnitAt(0) == 0xFEFF) {
      normalized = normalized.substring(1);
    }
    return normalized;
  }

  String? _normalizeUtf8BytesForComparison(Uint8List bytes) {
    final text = _tryDecodeUtf8(bytes);
    if (text == null) return null;
    return _normalizeTextForComparison(text);
  }

  bool _isValidTrackName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    return RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(trimmed);
  }

  Future<void> _saveRemoteMeta(RepoContext context, RepoMeta meta) async {
    final metaFile = File(p.join(context.remoteRepoDir.path, remoteMetaFileName));
    await metaFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(meta.toJson()),
      flush: true,
    );
  }

  Future<void> trackList() async {
    final context = await loadRepoContext();
    if (context == null) return;

    final trackNames = context.remoteMeta.tracks.keys.toList()..sort();

    print('\n🎯 ${"Tracks".cyan}');
    print('═' * 60);

    for (var i = 0; i < trackNames.length; i++) {
      final name = trackNames[i];
      final track = context.remoteMeta.tracks[name]!;
      final isActive = name == context.remoteMeta.activeTrack;

      print(
        '[${i.toString().padLeft(2, '0')}] '
        '${name.green}'
        '${isActive ? " ${"(active)".cyan}" : ""}',
      );
      print('     ${"Snapshots:".yellow.padRight(12)} ${track.logs.length.toString().green}');
    }

    print('═' * 60);
    print('');
  }

  Future<void> trackCurrent() async {
    final context = await loadRepoContext();
    if (context == null) return;

    print('\n🎯 ${"Current track".cyan}');
    print('═' * 60);
    print('${"Name:".yellow.padRight(12)} ${context.remoteMeta.activeTrack.green}');
    print(
      '${"Snapshots:".yellow.padRight(12)} '
      '${context.remoteMeta.tracks[context.remoteMeta.activeTrack]!.logs.length.toString().green}',
    );
    print('═' * 60);
    print('');
  }

  Future<void> trackCreate(String name) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final trackName = name.trim();

    if (!_isValidTrackName(trackName)) {
      print('❌ ${"Invalid track name.".red} Use only letters, numbers, "_" and "-".');
      return;
    }

    if (context.remoteMeta.tracks.containsKey(trackName)) {
      print('❌ ${"Track already exists:".red} $trackName');
      return;
    }

    final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
    updatedTracks[trackName] = TrackState(logs: []);

    final updatedMeta = context.remoteMeta.copyWith(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      tracks: updatedTracks,
    );

    await _saveRemoteMeta(context, updatedMeta);

    print('✅ ${"Track created:".green} $trackName');
  }

  Future<void> trackDelete(String name) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final trackName = name.trim();

    if (!context.remoteMeta.tracks.containsKey(trackName)) {
      print('❌ ${"Track not found:".red} $trackName');
      return;
    }

    if (trackName == 'main') {
      print('❌ ${'The "main" track cannot be deleted.'.red}');
      return;
    }

    if (trackName == context.remoteMeta.activeTrack) {
      print('❌ ${"Cannot delete the active track.".red}');
      return;
    }

    final snapshotCount = context.remoteMeta.tracks[trackName]!.logs.length;
    if (!confirmAction('Delete track "$trackName" with $snapshotCount snapshot(s)?')) {
      print('Cancelled.');
      return;
    }

    final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
    updatedTracks.remove(trackName);

    final updatedMeta = context.remoteMeta.copyWith(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      tracks: updatedTracks,
    );

    await _saveRemoteMeta(context, updatedMeta);

    print('✅ ${"Track deleted:".green} $trackName');
  }

  Future<void> trackSwitch(String name, {String? password, bool? webRestore}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final trackName = name.trim();

    if (!context.remoteMeta.tracks.containsKey(trackName)) {
      print('❌ Track not found: $trackName');
      return;
    }

    if (trackName == context.remoteMeta.activeTrack) {
      print('ℹ️ Already on track: $trackName');
      return;
    }

    final targetTrack = context.remoteMeta.tracks[trackName]!;

    final updatedMeta = context.remoteMeta.copyWith(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      activeTrack: trackName,
    );

    await _saveRemoteMeta(context, updatedMeta);

    if (targetTrack.logs.isEmpty) {
      print('✅ Switched to track: $trackName');
      print('ℹ️ Track is empty. Next push will start its history.');
      return;
    }

    bool proceedWithRestore = false;

    if (webRestore != null) {
      proceedWithRestore = webRestore;
    } else {
      proceedWithRestore = confirmAction(
        'Track "$trackName" has snapshots. Restore its latest snapshot into the working tree now?'
      );
    }

    if (!proceedWithRestore) {
      print('✅ Switched to track: $trackName');
      print('ℹ️ Working tree was NOT restored.');
      return;
    }

    final String? finalPassword = password ?? askPassword();
    
    if (finalPassword == null || finalPassword.isEmpty) {
      print('✅ Switched to track: $trackName');
      print('⚠️ Working tree not updated (Password required for decryption).');
      return;
    }

    final latest = targetTrack.logs.first;

    final refreshedContext = await loadRepoContext();
    if (refreshedContext == null) return;

    final snapshot = await readSnapshot(
      refreshedContext,
      latest.id,
      password: finalPassword,
    );

    if (snapshot == null) {
      print('ℹ️ Switched to track: $trackName (Tree restore failed: Wrong password)');
      return;
    }

    await _restoreSnapshotIntoWorkingTree(refreshedContext, snapshot);

    print('✅ Switched to track: $trackName');
    print('✅ Restored latest snapshot: ${latest.id}');
  }

  Future<void> launchUI({int port = 8080}) async {
    var context = await loadRepoContext();
    if (context == null) {
      print('❌ No active repository found.'.red);
      return;
    }

    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      final url = 'http://localhost:$port';
      print('\n🌐 Portable VCS Web Terminal active at: $url'.cyan);

      await _openBrowser(url);

      await for (HttpRequest request in server) {
        final path = request.uri.path;
        final params = request.uri.queryParameters;

        if (path == '/') {
          final freshContext = await loadRepoContext();
          request.response
            ..headers.contentType = ContentType.html
            ..write(_generateDashboardHtml(freshContext!.remoteMeta))
            ..close();
        } 
        
        else if (path == '/api/command') {
          final rawInput = params['raw'] ?? '';
          final webPass = params['password'];
          String output = '';

          if (rawInput.isEmpty) {
            request.response..statusCode = 400..close();
            continue;
          }

          await runZoned(() async {
            final buffer = StringBuffer();
            await runZoned(() async {
              try {
                final args = _parseRawCommand(rawInput);
                await runWithArgs(args, this, password: webPass);
                
              } catch (e) {
                print('❌ Execution Error: $e');
              }
            }, zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) => buffer.writeln(line),
            ));

            output = _ansiToHtml(buffer.toString());
          });

          final cmdName = rawInput.split(' ')[0];
          final refreshCommands = ['push', 'pull', 'track', 'revert', 'purge', 'init', 'bind'];
          bool shouldRefresh = refreshCommands.contains(cmdName);

          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'success': true, 
              'output': output.isEmpty ? 'Done.' : output,
              'refresh': shouldRefresh
            }))
            ..close();
        }
        
        else if (path == '/api/inspect') {
          final id = params['id'];
          final pass = params['password'];
          try {
            final snapshot = await readSnapshot(context!, id!, password: pass!);
            if (snapshot != null) {
              final logEntry = context.remoteMeta.logs.firstWhere((l) => l.id == id);
              final summary = logEntry.changeSummary;
              final archive = ZipDecoder().decodeBytes(snapshot.zipBytes);
              final files = archive.files.where((f) => f.isFile).map((f) {
                String status = 'unchanged';
                for (var c in summary) {
                  if (c.contains(f.name)) {
                    if (c.startsWith('[N]')) status = 'added';
                    else if (c.startsWith('[M]')) status = 'modified';
                    else if (c.startsWith('[D]')) status = 'deleted';
                  }
                }
                return {'name': f.name, 'status': status};
              }).toList();
              request.response..headers.contentType = ContentType.json
                ..write(jsonEncode({'success': true, 'files': files}))..close();
            } else {
              request.response..statusCode = 401..write(jsonEncode({'success': false}))..close();
            }
          } catch (e) {
            request.response..statusCode = 500..write(jsonEncode({'success': false, 'error': e.toString()}))..close();
          }
        }

        else if (path == '/api/switch-track') {
          final targetTrack = params['name'];
          final webPass = params['password'];
          final shouldRestore = params['restore'] == 'true'; 

          if (targetTrack != null) {
            await runZoned(() async {
              await trackSwitch(
                targetTrack, 
                password: webPass, 
                webRestore: shouldRestore
              ); 
            }, zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) => stdout.writeln(line),
            ));
            
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'success': true}))
              ..close();
          }
        }
        
        else if (path == '/api/content') {
          final id = params['id'];
          final pass = params['password'];
          final fileName = params['file'];
          
          try {
            final currentSnapshot = await readSnapshot(context!, id!, password: pass!);
            if (currentSnapshot == null) throw 'Snapshot not found';
            
            final currentArchive = ZipDecoder().decodeBytes(currentSnapshot.zipBytes);
            final currentFile = currentArchive.findFile(fileName!);
            final String currentText = currentFile != null ? utf8.decode(currentFile.content) : '';

            final logs = context.remoteMeta.logs;
            final currentIndex = logs.indexWhere((l) => l.id == id);
            
            Map<String, String> diffResult;

            if (currentIndex != -1 && currentIndex < logs.length - 1) {
              final prevLog = logs[currentIndex + 1];
              final prevSnapshot = await readSnapshot(context, prevLog.id, password: pass);
              
              if (prevSnapshot != null) {
                final prevArchive = ZipDecoder().decodeBytes(prevSnapshot.zipBytes);
                final prevFile = prevArchive.findFile(fileName);
                
                if (prevFile != null) {
                  final String prevText = utf8.decode(prevFile.content);
                  diffResult = _generateSplitDiff(prevText, currentText);
                } else {
                  diffResult = _generateSplitDiff('', currentText);
                }
              } else {
                diffResult = _generateSplitDiff('', currentText);
              }
            } else {
              diffResult = _generateSplitDiff('', currentText);
            }

            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(diffResult))
              ..close();

          } catch (e) {
            request.response
              ..statusCode = 500
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'error': e.toString()}))
              ..close();
          }
        }
        else { request.response..statusCode = 404..close(); }
      }
    } catch (e) {
      print('❌ Server error: $e'.red);
    }
  }

  Map<String, String> _generateSplitDiff(String oldText, String newText) {
    List<String> oldLines = oldText.split('\n');
    List<String> newLines = newText.split('\n');
    
    StringBuffer leftHtml = StringBuffer();
    StringBuffer rightHtml = StringBuffer();

    int i = 0;
    int j = 0;

    String escape(String text) => text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');

    while (i < oldLines.length || j < newLines.length) {
      String? lineOld = i < oldLines.length ? oldLines[i] : null;
      String? lineNew = j < newLines.length ? newLines[j] : null;

      if (lineOld != null && lineNew != null && lineOld == lineNew) {
        leftHtml.writeln('<div class="diff-line">${escape(lineOld)}</div>');
        rightHtml.writeln('<div class="diff-line">${escape(lineNew)}</div>');
        i++; j++;
      } else {
        int lookAhead = 10;
        int matchIndex = -1;
        
        if (lineOld != null) {
          for (int k = j + 1; k < newLines.length && k < j + lookAhead; k++) {
            if (newLines[k] == lineOld) {
              matchIndex = k;
              break;
            }
          }
        }

        if (matchIndex != -1) {
          while (j < matchIndex) {
            leftHtml.writeln('<div class="diff-line empty"> </div>');
            rightHtml.writeln('<div class="diff-line add">+ ${escape(newLines[j])}</div>');
            j++;
          }
        } else {
          if (i < oldLines.length) {
            leftHtml.writeln('<div class="diff-line del">- ${escape(oldLines[i])}</div>');
            i++;
          } else {
            leftHtml.writeln('<div class="diff-line empty"> </div>');
          }

          if (j < newLines.length) {
            rightHtml.writeln('<div class="diff-line add">+ ${escape(newLines[j])}</div>');
            j++;
          } else {
            rightHtml.writeln('<div class="diff-line empty"> </div>');
          }
        }
      }
    }

    return {
      "left": leftHtml.toString(),
      "right": rightHtml.toString()
    };
  }

  List<String> _parseRawCommand(String input) {
    final shellRegex = RegExp(r'([^\s"理論]+)|"([^"]*)"');
    return shellRegex.allMatches(input)
        .map((m) => m.group(2) ?? m.group(1) ?? '')
        .toList();
  }

  String _ansiToHtml(String text, {bool isNewFile = false}) {
    String cleanText = text
        .replaceAll('[0m', '</span>')
        .replaceAll('[32m', '<span style="color:var(--added)">')
        .replaceAll('[31m', '<span style="color:var(--error)">')
        .replaceAll('[33m', '<span style="color:var(--warning)">')
        .replaceAll('[36m', '<span style="color:var(--accent)">')
        .replaceAll('[1m', '<span style="font-weight:bold">')
        .replaceAll(RegExp(r'\[[0-9;]*m'), '');

    if (isNewFile) {
      final escaped = cleanText
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');

      return escaped.split('\n').map((line) {
        if (line.trim().isEmpty) return '<div class="diff-line"> </div>';
        return '<div class="diff-line add">+ $line</div>';
      }).join('\n');
    }

    return cleanText.replaceAll('\n', '<br>');
  }

  String _generateDashboardHtml(RepoMeta meta) {
    final String css = r"""
            :root { 
              --bg: #0d1117; --card: #161b22; --accent: #58a6ff; 
              --border: #30363d; --text: #c9d1d9; --text-dim: #8b949e;
              --success: #238636; --error: #f85149; --warning: #d29922;
              --added: #3fb950; --modified: #d29922; --deleted: #f85149;
              --term-bg: #010409;
            }
            * { box-sizing: border-box; }
            body { 
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; 
              background: var(--bg); color: var(--text); margin: 0; display: flex; height: 100vh; overflow: hidden;
            }
            
            .sidebar { 
              width: 300px; border-right: 1px solid var(--border); padding: 25px; 
              display: flex; flex-direction: column; background: #010409;
            }
            .stats-card { background: var(--card); border: 1px solid var(--border); padding: 12px; border-radius: 8px; margin-bottom: 10px; }
            .stat-label { font-size: 10px; text-transform: uppercase; color: var(--text-dim); letter-spacing: 1px; }
            .stat-value { font-size: 14px; font-weight: bold; color: var(--accent); display: block; margin-top: 2px; }

            .actions-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 20px; }
            .btn-action { 
              background: var(--card); border: 1px solid var(--border); color: var(--text); padding: 12px;
              border-radius: 6px; cursor: pointer; font-size: 12px; font-weight: 600; transition: 0.2s;
              display: flex; flex-direction: column; align-items: center; gap: 4px;
            }
            .btn-action:hover { border-color: var(--accent); background: #1c2128; transform: translateY(-2px); }

            .workspace { flex: 1; display: flex; flex-direction: column; height: 100vh; }
            .main-content { flex: 1; overflow-y: auto; padding: 40px; }
            
            .terminal-container {
              height: 250px; background: var(--term-bg); border-top: 1px solid var(--border);
              display: flex; flex-direction: column; font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
            }
            .terminal-output { flex: 1; overflow-y: auto; padding: 15px; font-size: 13px; line-height: 1.5; color: #d1d5da; }
            .terminal-output div { white-space: pre-wrap; word-break: break-all; }
            .terminal-input-area { 
              display: flex; align-items: center; padding: 10px 15px; background: #090c10; border-top: 1px solid #21262d;
            }
            .prompt { color: var(--added); margin-right: 10px; font-weight: bold; }
            .cmd-input { 
              flex: 1; background: transparent; border: none; color: white; font-family: inherit; font-size: 14px; outline: none;
            }

            .snapshot-card { 
              background: var(--card); border: 1px solid var(--border); padding: 15px; 
              margin-bottom: 10px; border-radius: 8px; cursor: pointer; 
              display: flex; justify-content: space-between; align-items: center; transition: 0.1s;
            }
            .snapshot-card:hover { border-color: var(--accent); background: #1c2128; }
            
            #codeViewer { 
              display: none; position: fixed; inset: 20px; background: var(--term-bg); border: 1px solid var(--border);
              border-radius: 12px; z-index: 1000; flex-direction: column; box-shadow: 0 20px 50px rgba(0,0,0,0.7);
            }

            /* Estilos para Vista Partida */
            .diff-container {
              display: grid; grid-template-columns: 1fr 1fr; gap: 1px;
              background: var(--border); flex: 1; overflow: hidden;
            }
            .diff-pane { 
              background: var(--term-bg); overflow: auto; padding: 20px 0;
              display: flex; flex-direction: column;
            }
            .diff-line { 
              white-space: pre; 
              font-family: 'SFMono-Regular', Consolas, monospace; 
              padding: 1px 15px; /* Reducido un poco el padding vertical */
              font-size: 12px; 
              height: 1.5em; /* Altura fija para forzar alineación */
              line-height: 1.5;
              display: block;
            }
            .diff-line.add { background-color: rgba(46, 160, 67, 0.15); color: #7ee787; border-left: 4px solid #3fb950; }
            .diff-line.del { background-color: rgba(248, 81, 73, 0.15); color: #ff7b72; border-left: 4px solid #f85149; }
            .diff-line.empty { background-color: rgba(0, 0, 0, 0.1); opacity: 0.5; }

            #passwordModal { 
              display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.85); 
              backdrop-filter: blur(4px); justify-content: center; align-items: center; z-index: 2000;
            }
            .modal-content { background: var(--card); padding: 30px; border-radius: 12px; border: 1px solid var(--border); width: 350px; text-align: center;}
            .modal-content input { 
              width: 100%; padding: 10px; background: var(--bg); border: 1px solid var(--border); 
              color: white; border-radius: 6px; margin: 15px 0; outline: none;
            }
            .badge-status { padding: 2px 6px; border-radius: 4px; font-size: 10px; border: 1px solid; }
            .added { color: var(--added); border-color: var(--added); }
            .modified { color: var(--modified); border-color: var(--modified); }
            .deleted { color: var(--deleted); border-color: var(--deleted); }

            .track-select {
              width: 100%; background: transparent; border: none; color: var(--added); 
              font-size: 14px; font-weight: bold; outline: none; cursor: pointer;
              padding: 0; margin-top: 2px; appearance: none;
            }
            .track-select option { background: var(--card); color: var(--text); }
        """;

    final snapshotsHtml = meta.logs.map((log) {
      return """
              <div class="snapshot-card" onclick="openInspector('${log.id}', '${log.message}')">
                <div>
                  <div style="font-weight:600; color:#f0f6fc;">${log.message}</div>
                  <div style="font-size:12px; color:var(--text-dim); margin-top:4px;">
                    <strong>${log.author ?? "Anonymous"}</strong> • ${log.createdAt}
                  </div>
                </div>
                <div style="font-family:monospace; font-size:11px; background:#30363d; padding:4px 8px; border-radius:4px;">${log.id}</div>
              </div>
            """;
    }).join('');

    final trackOptions = meta.tracks.keys
        .map((t) => '<option value="$t" ${t == meta.activeTrack ? 'selected' : ''}>$t</option>')
        .join('');

    return r"""
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <title>VCS Terminal Dashboard</title>
            <style>""" + css + r"""</style>
          </head>
          <body>
            <div class="sidebar">
              <h2 style="font-size: 18px; margin-bottom: 20px;">📁 Repository</h2>
              <div class="stats-card">
                <span class="stat-label">Project</span>
                <span class="stat-value">""" + meta.projectName + r"""</span>
              </div>
              
              <div class="stats-card">
                <span class="stat-label">Active Track</span>
                <select class="track-select" onchange="switchTrack(this.value)">
                  """ + trackOptions + r"""
                </select>
              </div>

              <div class="actions-grid">
                <button class="btn-action" onclick="setCmd('status')">🔍 Status</button>
                <button class="btn-action" onclick="setCmd('diff')">🌓 Diff</button>
                <button class="btn-action" onclick="setCmd('push \"\" -a ')">📤 Push</button>
                <button class="btn-action" onclick="setCmd('pull')">📥 Pull</button>
                <button class="btn-action" onclick="setCmd('publish --branch main')">🚀 Publish</button>
                <button class="btn-action" onclick="setCmd('doctor')">🩺 Doctor</button>
                <button class="btn-action" onclick="executeRaw('help')" style="grid-column: span 2; border-color: var(--warning);">❓ Help Guide</button>
              </div>
            </div>

            <div class="workspace">
              <div class="main-content">
                <div id="viewList">
                  <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:20px;">
                    <h1 style="font-size:24px;">History</h1>
                    <input type="text" placeholder="Filter..." oninput="filterLogs(this.value)" style="background:var(--card); border:1px solid var(--border); color:white; padding:8px; border-radius:6px; outline:none;">
                  </div>
                  <div id="snapshotList">""" + snapshotsHtml + r"""</div>
                </div>

                <div id="fileInspector" style="display:none">
                  <button onclick="closeInspector()" style="background:transparent; color:var(--accent); border:none; cursor:pointer; padding:0; margin-bottom:10px;">&larr; Back to snapshots</button>
                  <h1 id="inspectTitle" style="margin:0 0 20px 0; font-size:24px;">Files</h1>
                  <div id="fileList" style="display:grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap:12px;"></div>
                </div>
              </div>

              <div class="terminal-container">
                <div class="terminal-output" id="termOut">Welcome to Portable VCS Web Terminal.</div>
                <div class="terminal-input-area">
                  <span class="prompt">vcs &gt;</span>
                  <input type="text" class="cmd-input" id="cmdIn" placeholder="Enter command..." autofocus onkeypress="handleTermKey(event)">
                </div>
              </div>
            </div>

            <div id="passwordModal">
              <div class="modal-content">
                <h3 id="modalTitle">🔒 Unlock Snapshot</h3>
                <input type="password" id="passInput" placeholder="Password...">
                <div style="display:flex; gap:10px;">
                  <button onclick="submitPassword()" style="flex:1; padding:10px; background:var(--success); color:white; border:none; border-radius:6px; cursor:pointer;">Confirm</button>
                  <button onclick="closeModal()" style="flex:1; background:transparent; color:var(--text-dim); border:none; cursor:pointer;">Cancel</button>
                </div>
              </div>
            </div>

            <div id="codeViewer">
              <div style="padding:15px; border-bottom:1px solid var(--border); display:flex; justify-content:space-between; align-items:center; background:#161b22;">
                <strong id="fileNameDisplay"></strong>
                <button onclick="closeCode()" style="background:var(--error); color:white; border:none; padding:5px 15px; border-radius:4px; cursor:pointer;">Close</button>
              </div>
              <div class="diff-container">
                  <div class="diff-pane" id="leftPane"></div>
                  <div class="diff-pane" id="rightPane"></div>
              </div>
            </div>

            <script>
              let currentId = null, currentPass = null;
              let pendingCommand = null;
              let pendingTrackName = null;
              let restoreDecision = false;

              function setCmd(c) {
                const input = document.getElementById('cmdIn');
                input.value = c;
                input.focus();
                if(c.includes('""')) {
                  const pos = c.indexOf('"') + 1;
                  input.setSelectionRange(pos, pos);
                }
              }

              async function switchTrack(trackName) {
                currentId = null; 
                pendingTrackName = trackName;
                restoreDecision = confirm(`Switched to track "${trackName}".\n\nDo you want to restore the latest snapshot?`);
                if (restoreDecision) {
                  document.getElementById('modalTitle').innerText = "🔑 Password to Restore Tree";
                  document.getElementById('passwordModal').style.display = 'flex';
                  document.getElementById('passInput').focus();
                } else {
                  executeSwitch(trackName, '', false);
                }
              }

              async function executeSwitch(name, pass, restore) {
                const out = document.getElementById('termOut');
                out.innerHTML += `<div style="color:var(--warning); margin-top:10px;">🔄 Switching to track: ${name}...</div>`;
                try {
                  const resp = await fetch(`/api/switch-track?name=${encodeURIComponent(name)}&password=${encodeURIComponent(pass)}&restore=${restore}`);
                  const data = await resp.json();
                  if (data.success) {
                    out.innerHTML += `<div style="color:var(--added)">✅ Track changed successfully.</div>`;
                    setTimeout(() => location.reload(), 600);
                  } else { alert("Error: " + data.error); }
                } catch(e) { alert("Network error"); }
              }

              function handleTermKey(e) {
                if(e.key === 'Enter') {
                  const raw = e.target.value.trim();
                  const needsAuth = ['push', 'pull', 'status', 'diff'].some(cmd => raw.startsWith(cmd));
                  if (needsAuth) {
                    pendingCommand = raw;
                    document.getElementById('modalTitle').innerText = "🔑 Authentication Required";
                    document.getElementById('passwordModal').style.display = 'flex';
                    document.getElementById('passInput').focus();
                  } else { executeRaw(raw); }
                }
              }

              async function executeRaw(raw, pass = '') {
                if(!raw.trim()) return;
                const out = document.getElementById('termOut');
                document.getElementById('cmdIn').value = '';
                out.innerHTML += `<div style="color:var(--accent); margin-top:10px;">$ vcs ${raw}</div>`;
                try {
                  const resp = await fetch(`/api/command?raw=${encodeURIComponent(raw)}&password=${encodeURIComponent(pass)}`);
                  const data = await resp.json();
                  out.innerHTML += `<div>${data.output.replace(/\n/g, '<br>')}</div>`;
                  out.scrollTop = out.scrollHeight;
                  if(data.refresh) setTimeout(() => location.reload(), 1500);
                } catch(e) { out.innerHTML += `<div style="color:var(--error)">Network error.</div>`; }
              }

              function openInspector(id, msg) {
                currentId = id;
                pendingCommand = null;
                pendingTrackName = null;
                document.getElementById('modalTitle').innerText = "🔒 Unlock Snapshot";
                document.getElementById('passwordModal').style.display = 'flex';
                document.getElementById('passInput').focus();
              }

              function closeModal() { 
                document.getElementById('passwordModal').style.display = 'none';
                document.getElementById('passInput').value = '';
              }

              function closeInspector() { 
                document.getElementById('fileInspector').style.display = 'none';
                document.getElementById('viewList').style.display = 'block';
              }

              async function submitPassword() {
                const pass = document.getElementById('passInput').value;
                if (pendingTrackName) {
                  const name = pendingTrackName;
                  closeModal();
                  await executeSwitch(name, pass, restoreDecision);
                  return;
                }
                if (pendingCommand) {
                  const cmd = pendingCommand;
                  pendingCommand = null;
                  closeModal();
                  executeRaw(cmd, pass);
                  return;
                }
                if (currentId) {
                  currentPass = pass;
                  try {
                    const resp = await fetch(`/api/inspect?id=${currentId}&password=${encodeURIComponent(pass)}`);
                    const data = await resp.json();
                    if (data.success) {
                      closeModal();
                      renderFiles(data.files);
                    } else { alert("Wrong password"); }
                  } catch(e) { alert("Error"); }
                }
              }

              function renderFiles(files) {
                document.getElementById('viewList').style.display = 'none';
                document.getElementById('fileInspector').style.display = 'block';
                document.getElementById('fileList').innerHTML = files.map(f => `
                  <div class="snapshot-card" onclick="viewCode('${f.name}')">
                    <span>📄 ${f.name}</span>
                    <span class="badge-status ${f.status}">${f.status}</span>
                  </div>
                `).join('');
              }

              async function viewCode(file) {
                try {
                  const resp = await fetch(`/api/content?id=${currentId}&password=${encodeURIComponent(currentPass)}&file=${encodeURIComponent(file)}`);
                  const data = await resp.json();
                  
                  document.getElementById('leftPane').innerHTML = data.left || '<div class="diff-line empty"> (New File) </div>';
                  document.getElementById('rightPane').innerHTML = data.right;
                  document.getElementById('fileNameDisplay').innerText = file;
                  document.getElementById('codeViewer').style.display = 'flex';

                  const left = document.getElementById('leftPane');
                  const right = document.getElementById('rightPane');
                  left.onscroll = () => { right.scrollTop = left.scrollTop; };
                  right.onscroll = () => { left.scrollTop = right.scrollTop; };

                } catch(e) { alert("Error loading diff"); }
              }
              
              function closeCode() { document.getElementById('codeViewer').style.display = 'none'; }
              
              function filterLogs(q) {
                const query = q.toLowerCase();
                document.querySelectorAll('#snapshotList .snapshot-card').forEach(c => {
                  c.style.display = c.innerText.toLowerCase().includes(query) ? 'flex' : 'none';
                });
              }
            </script>
          </body>
          </html>
          """;
  }

  Future<void> _openBrowser(String url) async {
    if (Platform.isWindows) {
      await Process.run('start', [url], runInShell: true);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    }
  }

  Future<void> showCommitHelper({String? track}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    print('\n📝 ${"SNAPSHOTS SUMMARY FOR COMMIT".black.onCyan}');
    print('${"Source Track:".yellow} ${targetTrackName.magenta.bold}');
    print('─' * 60);

    if (trackData == null || trackData.logs.isEmpty) {
      print('ℹ️ ${"No snapshots found in this track.".grey}');
      return;
    }

    print('${"Copy these points into your Git commit:".bold}\n');

    final history = trackData.logs.reversed.toList();

    for (final entry in history) {
      final date = _formatDateForList(entry.createdAt).grey;
      print('  ${"•".cyan} ${entry.message} ${"($date)".grey}');
      
      for (var fileChange in entry.changeSummary) {
        print('    ${"└".grey} $fileChange');
      }
    }

    print('\n' + '─' * 60);
    print('💡 ${'Recommended:'.grey} git commit -m "Update from Portable-VCS" -m "\$(vcs summary)"');
    print('');
  }
}

extension ColorConsole on String {
  String get green => '\x1B[32m$this\x1B[0m';
  String get yellow => '\x1B[33m$this\x1B[0m';
  String get red => '\x1B[31m$this\x1B[0m';
  String get cyan => '\x1B[36m$this\x1B[0m';
  String get blue => '\x1B[34m$this\x1B[0m';
  String get magenta => '\x1B[35m$this\x1B[0m';
  String get white => '\x1B[37m$this\x1B[0m';
  String get grey => '\x1B[90m$this\x1B[0m';
  String get bold => '\x1B[1m$this\x1B[0m';
  String get italic => '\x1B[3m$this\x1B[0m';
  String get underline => '\x1B[4m$this\x1B[0m';
  String get onCyan => '\x1B[46m$this\x1B[0m';
  String get onRed => '\x1B[41m$this\x1B[0m';
  String get onGreen => '\x1B[42m$this\x1B[0m';
  String get onYellow => '\x1B[43m$this\x1B[0m';

  String get black => '\x1B[30m$this\x1B[0m';
}

Future<void> main(List<String> args) async {
  final app = PortableVcs();
  await runWithArgs(args, app);
}


Future<void> runWithArgs(List<String> args, PortableVcs app, {String? password}) async {
  app.currentWebPassword = password;
  

  final parser = ArgParser()
    ..addCommand('setup')
    ..addCommand('init')
    ..addCommand('status')
    ..addCommand(
      'log',
      ArgParser()
        ..addFlag('full', negatable: false)
        ..addFlag('summary', negatable: false)
        ..addFlag('standard', negatable: false)
        ..addOption('track', abbr: 't', help: 'Show logs from a specific track instead of the active one',),
    )
    ..addCommand('show', ArgParser()
      ..addOption('track', abbr: 't', help: 'Target track to look for the snapshot')
    )
    ..addCommand(
      'pull',
      ArgParser()
        ..addOption('track', abbr: 't', help: 'Pull from a specific track')
        ..addOption('id', help: 'Pull a specific snapshot ID'),
    )
    ..addCommand('list')
    ..addCommand('doctor')
    ..addCommand('stats')
    ..addCommand('summary', ArgParser()
      ..addOption('track', abbr: 't', help: 'Get summary from a specific track')
      ..addFlag('copy', abbr: 'c', negatable: false, help: 'Copy to clipboard (if supported)')
    )
    ..addCommand('help')
    ..addCommand('clear-history')
    ..addCommand('purge')
    ..addCommand(
      'verify',
      ArgParser()
        ..addFlag(
          'all',
          negatable: false,
          help: 'Verify all snapshots in repository',
        ),
    )
    ..addCommand('bind')
    ..addCommand('diff', ArgParser())
    ..addCommand('tree', ArgParser()
      ..addOption('track', abbr: 't', help: 'Target track to visualize')
    )
    ..addCommand(
      'push',
      ArgParser()..addOption('author', abbr: 'a')
      ..addOption('track', abbr: 't', help: 'Push to a specific track instead of the active one'),
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
      'git-diff',
      ArgParser()
        ..addOption('branch', defaultsTo: 'main'),
    )
    ..addCommand(
      'track',
      ArgParser()
        ..addCommand('list')
        ..addCommand('current')
        ..addCommand('create')
        ..addCommand('switch')
        ..addCommand('delete'),
    )
    ..addCommand('version')
    ..addCommand('ui')
    ..addCommand(
      'publish',
      ArgParser()
        ..addOption('branch', defaultsTo: 'main', abbr: 'b')
        ..addOption('remote', defaultsTo: 'origin', abbr: 'r')
        ..addFlag('dry-run', negatable: false)
        ..addFlag('verify', defaultsTo: true, help: 'Run security hooks before publishing'),
    );

  if (args.isEmpty) {
    app.showHelp();
    return;
  }

  try {
    final result = parser.parse(args);
    switch (result.command?.name) {
      case 'version':
        print(version.cyan);
        break;
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
        final cmd = result.command!;
        LogViewMode mode = LogViewMode.summary;
        if (cmd['full'] == true) mode = LogViewMode.full;
        else if (cmd['standard'] == true) mode = LogViewMode.standard;
        
        await app.log(
          mode: mode, 
          track: cmd['track']?.toString()
        );
        break;
      case 'show':
        final cmd = result.command!;
        final rest = cmd.rest;
        
        if (rest.isEmpty) {
          print('❌ You must provide a snapshot ID.');
          return;
        }

        final snapshotId = rest.first;
        final track = cmd['track'] as String?;

        await app.showSnapshot(snapshotId, track: track);
        break;
      case 'doctor':
        await app.doctor();
        break;
      case 'stats':
        await app.stats();
        break;
      case 'pull':
        final pullCmd = result.command!;
        await app.pull(
          track: pullCmd['track']?.toString(),
          snapshotId: pullCmd['id']?.toString(),
        );
        break;
      case 'clear-history':
        await app.clearHistory();
        break;
      case 'purge':
        await app.purge();
        break;
      case 'verify':
        final cmd = result.command!;
        final verifyAll = cmd['all'] == true;
        final rest = cmd.rest;
        final snapshotId = rest.isNotEmpty ? rest.first : null;

        await app.verify(
          snapshotId: snapshotId,
          verifyAll: verifyAll,
        );
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
          track: pushCmd['track']?.toString(),
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
          verify: cmd['verify'] == true,
        );
        break;
      case 'tree':
        final cmd = result.command!;
        final rest = cmd.rest;
        final snapshotId = rest.isNotEmpty ? rest.first : null;
        final track = cmd['track'] as String?;
        await app.tree(snapshotId, track);
        break;
      case 'git-diff':
        final cmd = result.command!;
        final snapshotId = cmd.rest.isNotEmpty ? cmd.rest.first : null;
        await app.gitDiff(
          snapshotId: snapshotId,
          branch: cmd['branch'].toString(),
        );
        break;
      case 'track':
        final trackCmd = result.command!;
        final sub = trackCmd.command;

        if (sub == null) {
          print('❌ ${"Usage: vcs track <list|current|create|switch|delete> [name]".red}');
          break;
        }

        switch (sub.name) {
          case 'list':
            await app.trackList();
            break;

          case 'current':
            await app.trackCurrent();
            break;

          case 'create':
            if (sub.rest.isEmpty) {
              print('❌ ${"Track name required.".red}');
            } else {
              await app.trackCreate(sub.rest.first);
            }
            break;

          case 'switch':
            if (sub.rest.isEmpty) {
              print('❌ ${"Track name required.".red}');
            } else {
              await app.trackSwitch(sub.rest.first);
            }
            break;

          case 'delete':
            if (sub.rest.isEmpty) {
              print('❌ ${"Track name required.".red}');
            } else {
              await app.trackDelete(sub.rest.first);
            }
            break;

          default:
            print('❌ ${"Usage: vcs track <list|current|create|switch|delete> [name]".red}');
        }
        break;
      case 'ui':
        await app.launchUI();
        break;
      case 'summary':
        final cmd = result.command!;
        await app.showCommitHelper(
          track: cmd['track']?.toString()
        );
        break;
      default:
        app.showHelp();
    }
  } catch (e) {
    print('❌ Error: $e');
  }
}
