import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' as crypto_alg;
import 'package:http/http.dart' as http;
import 'package:vcs/models/alias_manager.dart';
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
import 'package:vcs/models/snapshot_notes.dart';
import 'package:vcs/models/track_state.dart';
import 'package:vcs/models/tree_node.dart';
import 'package:vcs/models/update_cache.dart';
import 'package:vcs/models/version_history.dart';

enum LogViewMode { summary, standard, full}
enum RemoteStatus { synced, ahead, behind, diverged, unknown }
const String vcsBaseVersion = '0.3.6-Experimental.2';

class PortableVcs {
  static const String driveMarkerFile = '.vcs_drive';
  static const String localMetaDirName = '.vcs';
  static const String localRepoFileName = 'repo.json';
  static const String remoteReposDir = 'repos';
  static const String remoteMetaFileName = 'meta.json';
  static const String lockFileName = '.lock';
  File get _cacheFile => File(p.join(Directory.systemTemp.path, '.vcs_update_cache'));
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

  String getFullVersion() {
    String osName = 'Unknown';
    if (Platform.isWindows) osName = 'Windows';
    else if (Platform.isLinux) osName = 'Linux';
    else if (Platform.isMacOS) osName = 'macOS';
    
    return '🚀 Portable VCS Version $vcsBaseVersion ($osName)';
  }

  Future<UpdateCache?> _loadCache() async {
    if (!_cacheFile.existsSync()) return null;
    try {
      final lines = await _cacheFile.readAsLines();
      return UpdateCache(lines[0], DateTime.parse(lines[1]));
    } catch (_) { return null; }
  }

  Future<void> _saveCache(String version) async {
    await _cacheFile.writeAsString('$version\n${DateTime.now().toIso8601String()}');
  }

  Future<void> update() async {
    const String owner = 'Nooch98';
    const String repo = 'Portable-VCS';
    const String branch = 'main';
    const String gitUrl = 'https://github.com/$owner/$repo.git';
    const String rawVersionUrl = 'https://raw.githubusercontent.com/$owner/$repo/$branch/lib/vcs.dart';

    print('\n✨ ${"VCS REMOTE UPDATE & COMPILE".black.onCyan}');

    bool isUpdateAvailable(String local, String remote) {
      try {
        if (local == remote) return false;
        List<int> parse(String v) {
          final clean = v.replaceAll('-Experimental.', '.').replaceAll('-', '.');
          return clean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
        }
        final localParts = parse(local);
        final remoteParts = parse(remote);
        final maxLen = localParts.length > remoteParts.length ? localParts.length : remoteParts.length;
        for (var i = 0; i < maxLen; i++) {
          final l = i < localParts.length ? localParts[i] : 0;
          final r = i < remoteParts.length ? remoteParts[i] : 0;
          if (r > l) return true;
          if (l > r) return false;
        }
      } catch (_) {
        return local != remote;
      }
      return false;
    }

    String detectedRemoteV = "";

    try {
      print('🔍 Checking for updates on GitHub ($branch)...');
      final versionResponse = await http.get(Uri.parse(rawVersionUrl));
      
      if (versionResponse.statusCode == 200) {
        final remoteContent = versionResponse.body;
        final versionRegex = RegExp(r"(?:vcsBaseVersion|baseVersion)\s*=\s*['" + '"' + r"]([^'" + '"' + r"]+)['" + '"' + r"]");
        final remoteMatch = versionRegex.firstMatch(remoteContent);
        
        if (remoteMatch != null) {
          detectedRemoteV = remoteMatch.group(1)!;
          final localV = vcsBaseVersion;
          
          if (!isUpdateAvailable(localV, detectedRemoteV)) {
            if (localV == detectedRemoteV) {
              print('✅ ${"You are already on the latest version ($localV).".green}');
            } else {
              print('🚀 ${"Local version ($localV) is ahead of GitHub ($detectedRemoteV).".magenta}');
            }
            
            stdout.write('Force re-download and re-compile? (y/n): ');
            final force = stdin.readLineSync();
            if (force?.toLowerCase() != 'y') return;
          } else {
            print('🚀 New version detected: ${localV.grey} -> ${detectedRemoteV.green.bold}');
          }
        } else {
          print('⚠️  Could not parse remote version. Proceeding with update anyway...');
        }
      }

      final tempDir = Directory(p.join(Directory.systemTemp.path, 'vcs_upgrade'));
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      await tempDir.create();

      print('📥 Cloning latest source code...');
      final cloneResult = await Process.run('git', [
        'clone', '--depth', '1', '--branch', branch, gitUrl, tempDir.path
      ]);

      if (cloneResult.exitCode != 0) {
        throw 'Failed to clone repository. Make sure "git" is installed.\n${cloneResult.stderr}';
      }

      File? vcsFile;
      File? pubspecFile;

      try {
        final allFiles = tempDir.listSync(recursive: true).whereType<File>();
        vcsFile = allFiles.firstWhere((f) => 
            p.basename(f.path) == 'vcs.dart' && 
            f.path.contains('${p.separator}lib${p.separator}'));
        pubspecFile = allFiles.firstWhere((f) => p.basename(f.path) == 'pubspec.yaml');
      } catch (_) {
        throw 'Could not locate lib/vcs.dart or pubspec.yaml in the cloned source.';
      }

      final sourceRoot = pubspecFile.parent.path;
      final String currentExePath = Platform.resolvedExecutable;
      final String newExeName = Platform.isWindows ? 'vcs_next.exe' : 'vcs_next';
      final newExePath = p.join(tempDir.path, newExeName);

      print('🛠️  Running pub get & Compiling binary...');
      print('   > Source found at: ${p.relative(vcsFile.path, from: tempDir.path).grey}');

      final pubResult = await Process.run('dart', ['pub', 'get'], 
        workingDirectory: sourceRoot, runInShell: true);

      if (pubResult.exitCode != 0) throw 'pub get failed: ${pubResult.stderr}';

      final compileResult = await Process.run('dart', [
        'compile', 'exe', vcsFile.path, '-o', newExePath
      ], workingDirectory: sourceRoot, runInShell: true);

      if (compileResult.exitCode != 0) throw 'Compilation failed: ${compileResult.stderr}';

      print('📦 Replacing binary at: ${currentExePath.grey}');

      if (Platform.isWindows) {
        final oldExe = File(currentExePath);
        final backupExe = File('$currentExePath.old');
        if (await backupExe.exists()) await backupExe.delete();
        
        try {
          await oldExe.rename(backupExe.path);
        } catch (e) {
          throw 'Could not rename current executable. Close any other VCS instances.';
        }
        await File(newExePath).copy(currentExePath);
      } else {
        try {
          await File(newExePath).copy(currentExePath);
          await Process.run('chmod', ['+x', currentExePath]);
        } catch (e) {
          print('\n${'❌ PERMISSION DENIED'.red.bold}');
          final sudoCmd = 'sudo cp "${newExePath}" "${currentExePath}" && sudo chmod +x "${currentExePath}"';
          print('Run: ${sudoCmd.cyan.bold}\n');
          return; 
        }
      }

      try { await tempDir.delete(recursive: true); } catch (_) {}

      print('\n🎉 ${"Update successful!".green.bold}');

      if (detectedRemoteV.isNotEmpty) {
        print('\n📜 ${"CHANGELOG: What\'s new in $detectedRemoteV".cyan.bold}');
        print('─' * 65);
        print(VersionHistory.getMarkdown(detectedRemoteV));
        print('─' * 65);
      }

      if (Platform.isWindows) {
        print('💡 ${"Note:".yellow} A ${".old".cyan} file was created. You can delete it now.');
      }
      print('Restart VCS to apply changes.\n');

    } catch (e) {
      print('❌ ${"Update failed:".red} $e');
    }
  }

  Future<String?> _getLatestGitHubVersion() async {
    try {
      final url = Uri.parse('https://raw.githubusercontent.com/Nooch98/Portable-VCS/main/lib/vcs.dart');      
      final response = await http.get(url).timeout(const Duration(seconds: 4));
      
      if (response.statusCode == 200) {
        final regExp = RegExp(r"vcsBaseVersion\s*=\s*['" + '"' + r"]([^'" + '"' + r"]+)['" + '"' + r"]");
        final match = regExp.firstMatch(response.body);
        
        if (match != null) {
          return match.group(1);
        }
      }
    } catch (e) {
      // silent
    }
    return null;
  }

  void _printUpdateToast(String current, String latest) {
    final String title = " UPGRADE New version available!";
    final String info = " ┃ $current → $latest";
    final String action = " ┃ Run vcs update to install.";

    final int width = [title.length, info.length, action.length].reduce((a, b) => a > b ? a : b) + 2;

    print('');
    print('  ${" UPGRADE ".black.onYellow.bold} ${"New version available!".yellow}');
    print('  ${"┃".yellow.bold}  ${current.grey} → ${latest.green.bold}');
    print('  ${"┃".yellow.bold}  Run ${"vcs update".cyan.bold} to install.');
    print('  ${"━" * width}\n'.grey);
  }

  Future<void> showVersion() async {
    final String currentFull = getFullVersion();
    final String dartVer = Platform.version.split(" ").first;
    final String os = Platform.operatingSystem;
    final String arch = Abi.current().toString().split('_').last;

    stdout.write('🔍 ${"Checking for updates...".grey}');
    final String? latestV = await _getLatestGitHubVersion();
    stdout.write('\r' + ' ' * 35 + '\r'); 

    bool isNewer(String local, String remote) {
      try {
        if (local == remote) return false;
        List<int> parse(String v) {
          final clean = v.replaceAll('-Experimental.', '.').replaceAll('-', '.');
          return clean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
        }
        final localParts = parse(local);
        final remoteParts = parse(remote);
        final maxLen = localParts.length > remoteParts.length ? localParts.length : remoteParts.length;
        for (var i = 0; i < maxLen; i++) {
          final l = i < localParts.length ? localParts[i] : 0;
          final r = i < remoteParts.length ? remoteParts[i] : 0;
          if (r > l) return true;
          if (l > r) return false;
        }
      } catch (_) {}
      return false;
    }

    final bool hasUpdate = latestV != null && isNewer(vcsBaseVersion, latestV);
    final bool isExp = currentFull.toLowerCase().contains('exp');

    print('\n' + '═' * 55);
    
    final badge = isExp ? "EXPERIMENTAL".black.onMagenta : "STABLE".black.onGreen;
    print('  ${'VCS'.cyan.bold} $badge ${'·'.grey} ${'The Secure Vault System'.white}');
    print('  ' + '─' * 51);

    print('  ${'Local Version:'.yellow.padRight(18)} ${currentFull.white.bold}');

    if (hasUpdate) {
      print('\n  ${'🚀 NEW VERSION READY:'.black.onYellow.bold} ${latestV!.green.bold}');
      print('  ${'Update command:'.grey} ${'vcs update'.white.bold}');
    } else if (latestV != null) {
      print('  ${'Status:'.yellow.padRight(18)} ${'Up to date'.green} (GitHub: $latestV)');
    } else {
      print('  ${'Status:'.yellow.padRight(18)} ${'Check failed (Offline)'.red}');
    }

    print('\n  ${'SYSTEM INFO'.bold.cyan}');
    print('  ' + '─' * 51);    
    print('  ${'Runtime:'.grey.padRight(18)} ${'Dart $dartVer ($arch)'.white}');
    print('  ${'Platform:'.grey.padRight(18)} ${os.toUpperCase().white}');
    print('  ${'Source:'.grey.padRight(18)} ${'https://github.com/Nooch98/Portable-VCS'.blue}');

    print('═' * 55 + '\n');
  }

  void showHelp() {
    const String helpMarkdown = '''

    # 🚀 PORTABLE SNAPSHOT VAULT [[ ${vcsBaseVersion} ]]

    > Offline encrypted snapshot tool for Git-compatible local workflows.


    ## 📂 REPOSITORY SETUP
    - `setup` Prepare a USB drive or external storage for VCS use.
    - `init` Initialize current project and link to remote storage.
    - `list` List repositories available on the connected storage.
    - `clone [repo_id]` Clone a repository from USB into a local folder.
      - `--into <dir>` Specify a custom directory name for the clone.
    - `bind [repo_id]` Bind current folder to an existing remote repository.

    ## 🛤️ TRACKS MANAGEMENT
    - `track list` List all available tracks.
    - `track current` Show the name of the active track.
    - `track create <name>` Create a new empty track.
    - `track switch <name>` Switch to another track.
      - `--restore` Optional: Restore the tree files upon switching.
    - `track delete <name>` Delete an existing non-active track.

    ## 📦 SNAPSHOT WORKFLOW
    - `push "message"` Create a snapshot (with preview & confirmation).
      - `-a, --author <name>` Override the author name for this snapshot.
      - `-t, --track <name>` Target a specific track instead of active.
      - `--amend` Overwrite the last snapshot in the track.
    - `tag <name>` Assign a friendly label to a snapshot.
      - `-i, --id <id>` Target a specific ID (defaults to latest).
      - `-t, --track <name>` Target a snapshot in a specific track.
    - `pull [id|tag]` Restore latest, specific ID or **tagged** snapshot.
      - `-t, --track <name>` Source snapshot from a specific track.
      - `--dry-run` Preview changes without applying.
    - `revert <id|tag>` Quick restore of a specific version from active track.
    - `restore <id|tag>` Restore a specific snapshot into another folder.
      - `--to <dir>` Destination path for the restored files.

    ## 📝 SNAPSHOT ANNOTATIONS
    - `note "text"` Add a technical note or comment to a snapshot.
      - `--id <id>` Target a specific snapshot (defaults to latest).
      - `-a, --author <name>` Set a custom author for the note.
      - `-r, --remove` Remove a note (requires `--index`).
      - `-i, --index <n>` The index of the note to remove (from `log`).
      - `--all` Remove all notes from the target snapshot.

    ## 🔍 INSPECTION & WEB INTERFACE
    - `ui` Launch the Web Dashboard (Split-view diff support).
    - `status` Compare local tree vs latest of the active track.
    - `timeline` Show an interactive or list-based chronological view.
      - `-t, --track <name>` Visualize a specific track.
      - `-n, --limit <n>` Number of snapshots to display (default: 15).
    - `search <query>` Search text inside encrypted snapshots.
      - `-t, --track <name>` Search only within a specific track.
      - `--id <snapshot_id>` Search only in a specific snapshot.
      - `-m, --max <n>` Search only in the last N snapshots.
      - `-s, --case-sensitive` Perform a case-sensitive search.
    - `info` Project overview, storage impact and activity charts.
      - `--charts` Display 7-day activity histogram.
    - `summary` Summary of messages to help create Git/GitHub commits.
    - `diff` Compare latest snapshot vs current live files.
    - `diff [id1] [id2|.]` Compare snapshots or snapshot vs working tree.
      - `-t, --tracks <tk1> <tk2>` Compare the last snapshot between two tracks.
    - `log` Show history of snapshots (includes **🏷️ Tags** and **📝 Notes**).
      - `--graph, -g` Visual representation of the snapshot timeline.
      - `--full` Show extended details (IDs, dates, metadata).
      - `--standard` Show summary with 5-file change preview.
      - `--summary` (Default) Show only statistics and message.
    - `show <id|tag>` Show details of a specific snapshot (including all notes).
    - `tree [id|tag]` Show visual file tree representation.
    - `verify <id|--all>` Verify cryptographic integrity of snapshots.

    ## ⌨️ ALIASES (USB Portable)
    - `alias --list, -l` List all custom shortcuts saved in the USB.
    - `alias --set "name=cmd"` Create a shortcut (e.g., `alias -s "st=status"`).
    - `alias --rm <name>` Remove a specific alias from the storage.

    ## 🐙 GIT INTEGRATION
    - `git-prepare [id|tag]` Prepare current Git repo from a snapshot.
    - `publish [id|tag]` Safe commit & push with remote conflict check.
      - `--branch <name>` Specify target branch for the push.
      - `--verify` Enforce security check for secrets.
    - `git-diff [id|tag]` Compare snapshot against current Git HEAD.
    - `stash` Manage Git stash (save current Git changes):
      - `--pop` Restore and remove last stash.
      - `--list` Show all currently stashed changes.

    ## 🛠️ MAINTENANCE
    - `update` Download latest source from GitHub and recompile.
    - `doctor` Run repository diagnostics, health checks and **meta-recovery**.
    - `stats` Show global repo metrics and track breakdown.
    - `benchmark` Performance stress test (IOPS, Crypto & Transfer speed).
      - `-i, --intensive` Run a high-load test with larger data buffers.
    - `prune` Clean up old snapshots:
      - `--id <id>` Delete a specific snapshot by its ID.
      - `--keep N` Keep only the newest N snapshots.
      - `--older-than N` Delete snapshots older than N days.
      - `--garbage` Deep clean: Remove orphaned data blobs.
    - `storage-check` Hardware diagnostic and latency test of the device.
      - `--full` Perform a more intensive read/write integrity check.
    - `migrate` Move your vault to a new drive or NAS:
      - `--to <path>` Target destination path for migration.
      - `--delete-source` Remove data from old drive after success.

    ## ⚙️ GENERAL
    - `help` Show this help message.
    - `version` Show tool version.
    - `changelog` Show changes of the version.

    ---

    ### 💡 PRO TIPS
    - **Note-taking:** Use `vcs note "Checked on Windows"` to document specific builds without re-pushing.
    - **Human-readable IDs:** Use `vcs tag stable` to avoid typing long IDs in `pull` or `diff`.
    - **Performance Check:** Run `vcs benchmark` if you feel the USB is slow; it helps identify hardware bottlenecks.
    - **Data Resilience:** The `doctor` command can restore metadata from backups if corruption occurs.
    - **USB Aliases:** Aliases are stored in the USB root, so they follow you to any computer.
    - All data is **AES-256 encrypted**. Keep your vault password safe.

    ''';

    print(_renderMarkdown(helpMarkdown));
  }

  void showChangelog() {
    final String content = VersionHistory.getMarkdown(vcsBaseVersion);
    
    final String changelogMarkdown = '''

    # 📜 CHANGELOG [[ V.${vcsBaseVersion} ]]

    > What's new in this release? Here is a summary of the latest changes.

    ${content}

    ---

    ### 💡 INFO
    - You are currently running the **Experimental** branch.
    - For full history and source code, visit the GitHub repository.

    ''';

    print(_renderMarkdown(changelogMarkdown));
  }

  Future<void> setupDrive() async {
    print('\n🔍 ${"SCANNING FOR EXTERNAL DRIVES".black.onCyan}');
    
    final candidates = await _listCandidateDrives();
    if (candidates.isEmpty) {
      print('❌ ${"No candidate drives found.".red}');
      return;
    }

    print('\n${"Select a drive to provision or upgrade:".bold}');
    print('═' * 70);
    for (var i = 0; i < candidates.length; i++) {
      final drive = candidates[i];
      final isWritable = _checkWriteAccess(drive.path);
      final markerExists = File(p.join(drive.path, driveMarkerFile)).existsSync();
      
      final status = isWritable ? 'READY'.green : 'READ-ONLY'.red;
      final type = markerExists ? ' [VCS DRIVE]'.cyan : ' [NEW]'.grey;
      
      print('  ${"[$i]".green.bold} ${drive.path.white.padRight(20)} $status$type');
    }
    print('═' * 70);

    stdout.write('\n👉 Select index or drive letter: ');
    final rawInput = stdin.readLineSync()?.trim().toUpperCase() ?? '';
    
    int? index = int.tryParse(rawInput);
    if (index == null) {
      for (var i = 0; i < candidates.length; i++) {
        if (candidates[i].path.toUpperCase().startsWith(rawInput)) {
          index = i;
          break;
        }
      }
    }

    if (index == null || index < 0 || index >= candidates.length) {
      print('❌ ${"Invalid selection.".red}');
      return;
    }

    final selected = candidates[index];
    final markerFile = File(p.join(selected.path, driveMarkerFile));
    final isUpgrade = markerFile.existsSync();

    print('\n🛠️  ${"PERFORMING PRE-FLIGHT CHECKS...".grey}');

    if (!_checkWriteAccess(selected.path)) {
      print('❌ ${"Write Test Failed:".red} Cannot write to ${selected.path}.');
      return;
    }

    if (isUpgrade) {
      print('\n✨ ${"UPGRADE MODE:".black.onCyan} This drive already has a VCS marker.');
      print('Metadata will be updated to v0.3 (Host, Date, OS) without touching your repositories.');
      stdout.write('Proceed with metadata upgrade? (y/N): ');
    } else {
      print('\n⚠️  ${"PROVISIONING MODE:".black.onYellow} You are about to prepare a new VCS drive.');
      print('This will create the marker and the ${remoteReposDir.cyan} directory.');
      stdout.write('Confirm provisioning? (y/N): ');
    }

    final confirm = stdin.readLineSync()?.toLowerCase();
    if (confirm != 'y' && confirm != 'yes') {
      print('🚫 Operation cancelled.');
      return;
    }

    print('\n⚙️  ${isUpgrade ? "Updating metadata..." : "Provisioning drive..."}');

    try {
      final hostname = Platform.localHostname;
      final metadata = [
        'portable-vcs',
        'version=0.3',
        'provisionedAt=${DateTime.now().toIso8601String()}',
        'provisionedBy=$hostname',
        'os=${Platform.operatingSystem}',
      ].join('\n');

      await markerFile.writeAsString(metadata, flush: true);

      final repoDir = Directory(p.join(selected.path, remoteReposDir));
      if (!repoDir.existsSync()) {
        await repoDir.create(recursive: true);
      }

      if (isUpgrade) {
        print('\n✅ ${"Upgrade successful!".green.bold}');
        print('📌 ${"New Identity:".grey} Linked to ${hostname.cyan}\n');
      } else {
        print('\n✅ ${"Vault prepared successfully!".green.bold}');
        print('📂 ${"Storage:".grey} ${repoDir.path}\n');
      }
      
    } catch (e) {
      print('❌ ${"Critical failure:".red} $e');
    }
  }

  bool _checkWriteAccess(String path) {
    try {
      final testFile = File(p.join(path, '.vcs_test_${DateTime.now().millisecondsSinceEpoch}'));
      testFile.writeAsStringSync('test');
      testFile.deleteSync();
      return true;
    } catch (_) {
      return false;
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

    print('\n📦 ${" VAULT REPOSITORY LIST ".black.onCyan}');
    print('${"USB Path:".grey} ${p.join(usb.path, remoteReposDir).grey}');
    print('═' * 70);

    final localId = await _readLocalRepoId();

    for (var i = 0; i < repos.length; i++) {
      final repo = repos[i];
      final meta = repo.meta;

      final snapshotsPath = p.join(usb.path, remoteReposDir, meta.repoId, 'snapshots');
      final snapshotsDir = Directory(snapshotsPath);
      
      double sizeMb = 0;
      if (snapshotsDir.existsSync()) {
        try {
          final totalBytes = snapshotsDir.listSync()
              .whereType<File>()
              .fold<int>(0, (sum, f) => sum + f.lengthSync());
          sizeMb = totalBytes / (1024 * 1024);
        } catch (_) {
          sizeMb = 0;
        }
      }

      final isLinked = localId == meta.repoId;
      final indexStr = '[${(i + 1).toString().padLeft(2, '0')}]'.green;
      
      int totalSnapshots = 0;
      meta.tracks.forEach((_, state) => totalSnapshots += state.logs.length);

      final statusBadge = isLinked ? " LINKED ".black.onMagenta : " REMOTE ".black.onBlue;
      final nameDisplay = isLinked ? meta.projectName.bold.white : meta.projectName.cyan;

      print('$indexStr $statusBadge $nameDisplay');
      print('     ${"ID:".grey} ${meta.repoId.white}');
      
      final stats = [
        '${meta.tracks.length} tracks'.yellow,
        '$totalSnapshots snapshots'.yellow,
        '${sizeMb.toStringAsFixed(1)} MB'.yellow,
      ].join(' ${"•".grey} ');

      print('     ${"Stats:".grey} $stats');
      print('     ${"Last Sync:".grey} ${_formatDateForList(meta.updatedAt).grey}');

      if (i < repos.length - 1) {
        print('     ' + '┈' * 55);
      }
    }

    print('═' * 70);
    print('💡 ${"Total:".cyan} ${repos.length} repositories found.');
    print('🚀 ${"To clone:".grey} ${"vcs clone <id_or_index>".green}');
    print('');
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
      print('\n❌ ${"No prepared USB drive found.".red}');
      return;
    }

    final repos = await _loadRemoteRepos(usb);
    if (repos.isEmpty) {
      print('\nℹ️  ${"No repositories found in vault.".yellow}');
      return;
    }

    RemoteRepoInfo? selected = _selectRemoteRepo(repos, repoId);
    if (selected == null) return;

    final activeTrack = selected.meta.activeTrack;
    final trackData = selected.meta.tracks[activeTrack];

    if (trackData == null || trackData.logs.isEmpty) {
      print('\n❌ ${"The repository has no snapshots in track: $activeTrack".red}');
      return;
    }

    final targetPath = into != null && into.trim().isNotEmpty
        ? p.normalize(p.isAbsolute(into) ? into : p.join(_cwd.path, into))
        : p.join(_cwd.path, selected.meta.projectName);

    final targetDir = Directory(targetPath);

    if (targetDir.existsSync() && targetDir.listSync().isNotEmpty) {
      print('\n❌ ${"Target folder is not empty:".red} $targetPath');
      return;
    }

    print('\n🚀 ${"CLONING PROJECT".black.onCyan}');
    print('${"Project:".grey} ${selected.meta.projectName.white.bold}');
    print('${"Track:".grey}   ${activeTrack.yellow}');
    print('${"Into:".grey}    ${targetPath.white}');
    print('─' * 50);

    final password = askPassword();
    if (password == null) return;

    stdout.write('📦 ${"Extracting latest snapshot...".grey}');
    
    final latestLog = trackData.logs.first;

    final snapshot = await readSnapshotByMeta(
      remoteRepoDir: selected.repoDir,
      remoteMeta: selected.meta,
      snapshotId: latestLog.id,
      password: password,
    );

    if (snapshot == null) {
      print('\r❌ ${"Failed to read snapshot. Check your password.".red}');
      return;
    }

    try {
      if (!targetDir.existsSync()) await targetDir.create(recursive: true);

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

      stdout.write('\r' + ' ' * 40 + '\r');
      print('✅ ${"Project successfully cloned!".green.bold}');
      print('─' * 50);
      print('${"Location:".grey}  ${targetDir.path.white}');
      print('${"Snapshot:".grey}  ${latestLog.id.yellow} (${_formatDateForList(latestLog.createdAt)})');
      print('\n💡 ${"Run".cyan} ${"vcs log".green} ${"in the folder to see the history.".grey}\n');

    } catch (e) {
      print('\r❌ ${"Clone failed: $e".red}');
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

  Future<void> addNote(String text, {String? snapshotId, String? author}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrack = context.remoteMeta.activeTrack;
    final trackState = context.remoteMeta.tracks[targetTrack];
    
    if (trackState == null || trackState.logs.isEmpty) {
      print('❌ No snapshots found in track $targetTrack');
      return;
    }

    final idToFind = snapshotId ?? trackState.logs.first.id;

    final newLogs = trackState.logs.map((entry) {
      if (entry.id == idToFind) {
        return entry.copyWithNote(SnapshotNote(
          text: text,
          author: author,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ));
      }
      return entry;
    }).toList();

    final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
    updatedTracks[targetTrack] = TrackState(logs: newLogs);

    final updatedMeta = context.remoteMeta.copyWith(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      tracks: updatedTracks,
    );

    final metaFile = File(p.join(context.remoteRepoDir.path, 'meta.json'));
    await _atomicWriteString(
      metaFile, 
      const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson())
    );

    print('✅ Note added to snapshot ${idToFind.cyan}.');
  }

  Future<void> removeNote({String? snapshotId, int? index, bool all = false}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrack = context.remoteMeta.activeTrack;
    final trackState = context.remoteMeta.tracks[targetTrack];
    
    if (trackState == null || trackState.logs.isEmpty) {
      print('❌ No snapshots found in track $targetTrack');
      return;
    }

    final idToFind = snapshotId ?? trackState.logs.first.id;
    bool found = false;

    final newLogs = trackState.logs.map((entry) {
      if (entry.id == idToFind) {
        found = true;
        if (all) {
          return entry.copyWithNotes([]);
        }
        
        if (index == null) {
          print('❌ You must specify a note index or use --all.');
          return entry;
        }

        if (index < 0 || index >= entry.notes.length) {
          print('❌ Invalid note index: $index. Snapshot has ${entry.notes.length} notes.');
          return entry;
        }

        final updatedNotes = List<SnapshotNote>.from(entry.notes)..removeAt(index);
        return SnapshotLogEntry(
          id: entry.id,
          message: entry.message,
          author: entry.author,
          createdAt: entry.createdAt,
          fileName: entry.fileName,
          changeSummary: entry.changeSummary,
          hash: entry.hash,
          notes: updatedNotes,
        );
      }
      return entry;
    }).toList();

    if (!found) {
      print('❌ Snapshot $idToFind not found.');
      return;
    }

    final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
    updatedTracks[targetTrack] = TrackState(logs: newLogs);

    final updatedMeta = context.remoteMeta.copyWith(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      tracks: updatedTracks,
    );

    final metaFile = File(p.join(context.remoteRepoDir.path, 'meta.json'));
    await _atomicWriteString(
      metaFile, 
      const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson())
    );

    print('✅ ${all ? "All notes" : "Note"} removed from snapshot ${idToFind.cyan}.');
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
      print('\n${"Untracked files (Initial commit):".bold}');
      print('  ${"(use \"vcs push <message>\" to create the initial snapshot)".grey}');
      for (final path in (current.keys.toList()..sort())) {
        print('    ${'NEW'.black.onGreen.padRight(7)} $path');
      }
      return;
    }

    final lastEntry = trackData.logs.first;
    final String? inputPassword = password ?? askPassword();
    if (inputPassword == null) return;

    final snapshot = await readSnapshot(
      context,
      lastEntry.id,
      password: inputPassword,
    );

    if (snapshot == null) return;

    final lastFingerprint = Map<String, String>.from(snapshot.fingerprint);
    final changes = diffFingerprints(lastFingerprint, current);

    if (changes.isEmpty) {
      print('\n✨ ${"Working tree clean.".green}');
      print('${"Your project is up to date with track".grey} ${targetTrackName.cyan}.');
      return;
    }

    Map<String, List<FileChange>> groups = {
      '🛠️  LOGIC': [],
      '🎨  ASSETS': [],
      '⚙️  CONFIG': [],
      '📄  OTHER': [],
    };

    for (final change in changes) {
      final ext = p.extension(change.path).toLowerCase();
      if (['.dart', '.js', '.py', '.cpp', '.h', '.ts', '.go', '.rs'].contains(ext)) {
        groups['🛠️  LOGIC']!.add(change);
      } else if (['.png', '.jpg', '.jpeg', '.svg', '.gif', '.webp', '.ico'].contains(ext)) {
        groups['🎨  ASSETS']!.add(change);
      } else if (['.yaml', '.json', '.xml', '.toml', '.lock', '.gradle', '.md'].contains(ext)) {
        groups['⚙️  CONFIG']!.add(change);
      } else {
        groups['📄  OTHER']!.add(change);
      }
    }

    print('\n${"Changes not yet pushed:".bold}');
    print('  ${"(use \"vcs push <message>\" to save these changes)".grey}\n');

    int added = 0, modified = 0, deleted = 0;

    groups.forEach((groupName, groupChanges) {
      if (groupChanges.isEmpty) return;

      print('  $groupName'.bold.underline);
      groupChanges.sort((a, b) => a.path.compareTo(b.path));

      for (final change in groupChanges) {
        String label;
        String coloredPath;

        switch (change.kind) {
          case ChangeKind.added:
            label = 'NEW'.black.onGreen;
            coloredPath = change.path.green;
            added++;
            break;
          case ChangeKind.modified:
            label = 'MOD'.black.onYellow;
            coloredPath = change.path.yellow;
            modified++;
            break;
          case ChangeKind.deleted:
            label = 'DEL'.black.onRed;
            coloredPath = change.path.red;
            deleted++;
            break;
        }
        
        print('    ${label.padRight(7)} $coloredPath');
      }
      print('');
    });

    print('  ' + '─' * 45);
    List<String> summaryParts = [];
    if (added > 0) summaryParts.add('${added} added'.green);
    if (modified > 0) summaryParts.add('${modified} modified'.yellow);
    if (deleted > 0) summaryParts.add('${deleted} deleted'.red);

    print('  ${"Summary:".cyan} ${summaryParts.join(', ')}');
    print('  ' + '─' * 45 + '\n');
  }

  Future<void> search(
    String query, {
    String? track, 
    bool caseSensitive = false,
    String? snapshotId,
    int? limit,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrack = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrack];

    if (trackData == null || trackData.logs.isEmpty) {
      print('ℹ️  ${"No snapshots found in track".yellow} "$targetTrack".');
      return;
    }

    List<SnapshotLogEntry> logsToSearch = List.from(trackData.logs);
    logsToSearch.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (snapshotId != null) {
      logsToSearch = logsToSearch.where((l) => l.id.toString() == snapshotId).toList();
    } else if (limit != null && limit > 0) {
      logsToSearch = logsToSearch.take(limit).toList();
    }

    final String searchQuery = caseSensitive ? query : query.toLowerCase();
    
    print('\n🔍 ${" SEARCHING METADATA & NOTES ".black.onCyan}');
    bool foundInMeta = false;

    for (final entry in logsToSearch) {
      bool matchInEntry = false;
      final msg = caseSensitive ? entry.message : entry.message.toLowerCase();

      if (msg.contains(searchQuery)) {
        print('\n📌 ${"Match in Snapshot Message:".cyan} ${entry.id.green}');
        print('   > ${entry.message.white.italic}');
        matchInEntry = true;
      }

      for (int i = 0; i < entry.notes.length; i++) {
        final note = entry.notes[i];
        final noteText = caseSensitive ? note.text : note.text.toLowerCase();
        
        if (noteText.contains(searchQuery)) {
          if (!matchInEntry) {
            print('\n📌 ${"Match in Notes:".cyan} ${entry.id.green} (${entry.message.grey})');
            matchInEntry = true;
          }
          print('   ${"Note [#$i]".yellow} ${note.author != null ? "[${note.author}]".grey : ""}');
          _printNoteHighlight(note.text, query, caseSensitive);
        }
      }
      if (matchInEntry) foundInMeta = true;
    }

    if (!foundInMeta) {
      print('  ${"No matches found in messages or notes.".grey}');
    }

    print('\n🚀 ${" PROCEED TO DEEP CONTENT SEARCH? ".black.onYellow}');
    stdout.write('This will decrypt snapshots. Continue? (y/N): ');
    if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') return;

    final password = askPassword();
    if (password == null || password.isEmpty) return;

    print('\n🔍 ${" DEEP CONTENT SEARCH ".black.onCyan}');
    print('═' * 60);

    int totalMatches = 0;
    int snapshotsWithMatches = 0;

    for (final entry in logsToSearch) {
      final String sId = entry.id.toString();
      final String shortId = sId.length > 8 ? sId.substring(0, 8) : sId;
      
      stdout.write('⏳ ${"Decrypting:".grey} ${shortId.cyan}...\r');

      try {
        final snapshot = await readSnapshot(context, sId, password: password);
        if (snapshot == null) continue;

        final files = await _decodeSnapshotFiles(snapshot);
        bool snapshotHasMatch = false;

        for (final fileName in files.keys) {
          final bytes = files[fileName]!;
          if (_isBinaryFile(fileName, bytes)) continue;

          String content;
          try {
            content = utf8.decode(bytes, allowMalformed: true);
          } catch (_) { continue; }

          final String contentToSearch = caseSensitive ? content : content.toLowerCase();

          if (contentToSearch.contains(searchQuery)) {
            final lines = content.split('\n');
            for (int i = 0; i < lines.length; i++) {
              final String lineToSearch = caseSensitive ? lines[i] : lines[i].toLowerCase();

              if (lineToSearch.contains(searchQuery)) {
                if (!snapshotHasMatch) {
                  stdout.write(' ' * 40 + '\r');
                  print('\n📦 Snapshot: ${sId.green} [${entry.message.toString().italic}]');
                  snapshotHasMatch = true;
                  snapshotsWithMatches++;
                }

                print('  📄 ${fileName.yellow}:${(i + 1).toString().white}');                
                _printSmartContext(lines, i, query, caseSensitive);
                
                totalMatches++;
                print('     ' + '┈' * 45);
              }
            }
          }
        }
      } catch (e) {
        print('\n⚠️  Error in $shortId: $e');
      }
    }

    print('\n' + '═' * 60);
    if (totalMatches > 0) {
      print('✅ Search finished. Found ${totalMatches.toString().green.bold} occurrences in ${snapshotsWithMatches.toString().cyan} snapshots.');
    } else {
      stdout.write(' ' * 40 + '\r');
      print('Status: ${"No matches found in file contents.".yellow}');
    }
  }

  void _printNoteHighlight(String text, String query, bool caseSensitive) {
    final lowerText = caseSensitive ? text : text.toLowerCase();
    final lowerQuery = caseSensitive ? query : query.toLowerCase();
    final matchIndex = lowerText.indexOf(lowerQuery);

    if (matchIndex != -1) {
      final before = text.substring(0, matchIndex);
      final match = text.substring(matchIndex, matchIndex + query.length);
      final after = text.substring(matchIndex + query.length);

      String display = "${before}${match.black.onYellow}${after}";
      if (display.length > 200) display = "${display.substring(0, 197)}...";
      
      print('   └─ $display');
    }
  }

  bool _isBinaryFile(String fileName, Uint8List bytes) {
    if (bytes.isEmpty) return false;
    const binaryExtensions = {
      '.exe', '.dll', '.bin', '.jpg', '.jpeg', 
      '.png', '.gif', '.zip', '.7z', '.rar', 
      '.pdf', '.ico', '.pyc', '.o', '.so'
    };

    if (fileName.contains('.')) {
      final ext = fileName.substring(fileName.lastIndexOf('.')).toLowerCase();
      if (binaryExtensions.contains(ext)) return true;
    }

    final checkLimit = bytes.length < 1024 ? bytes.length : 1024;
    for (var i = 0; i < checkLimit; i++) {
      if (bytes[i] == 0) return true; 
    }

    return false;
  }

  void _printSmartContext(List<String> lines, int index, String query, bool caseSensitive) {
    const int maxLines = 10; 
    int lastLineToPrint = index + 3;
    
    final String currentLine = lines[index];
    
    bool isBlockStart = currentLine.contains('{') || 
                        (index + 1 < lines.length && _getIndent(lines[index + 1]) > _getIndent(currentLine));

    if (isBlockStart) {
      int openBraces = _countChar(currentLine, '{');
      int closeBraces = _countChar(currentLine, '}');
      
      for (int j = index + 1; j < lines.length && j < index + maxLines; j++) {
        lastLineToPrint = j;
        openBraces += _countChar(lines[j], '{');
        closeBraces += _countChar(lines[j], '}');
        if (openBraces > 0 && openBraces == closeBraces) break;
        if (openBraces == 0 && lines[j].trim().isNotEmpty && _getIndent(lines[j]) <= _getIndent(currentLine)) break;
      }
    }

    if (lastLineToPrint >= lines.length) lastLineToPrint = lines.length - 1;

    for (int k = index; k <= lastLineToPrint; k++) {
      final String l = lines[k];
      final bool isMainLine = k == index;
      
      final String gutter = isMainLine ? ' → '.cyan : '   '.grey;
      String content = l.trim();
      if (content.length > 120) content = '${content.substring(0, 117)}...';

      String displayContent;
      if (isMainLine) {
        final String lowerContent = caseSensitive ? content : content.toLowerCase();
        final String lowerQuery = caseSensitive ? query : query.toLowerCase();
        final int matchIndex = lowerContent.indexOf(lowerQuery);

        if (matchIndex != -1) {
          final before = content.substring(0, matchIndex);
          final match = content.substring(matchIndex, matchIndex + query.length);
          final after = content.substring(matchIndex + query.length);
          displayContent = "${before.white}${match.black.onYellow}${after.white}";
        } else {
          displayContent = content.white;
        }
      } else {
        displayContent = content.grey;
      }

      print('     $gutter $displayContent');
    }
  }

  int _getIndent(String line) => line.length - line.trimLeft().length;
  int _countChar(String line, String char) => char.allMatches(line).length;

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
        rightLabel = 'working-tree (live)';
      } 

      else if (args.length == 1) {
        final id = resolveId(args[0]);
        if (id == null) return;

        final snapshot = await readSnapshot(context, id, password: finalPassword);
        if (snapshot == null) return;

        leftFiles = await _decodeSnapshotFiles(snapshot);
        rightFiles = await _readCurrentProjectFiles();
        leftLabel = 'snapshot:$id';
        rightLabel = 'working-tree (live)';
      } 

      else if (args.length == 2) {
        final String argLeft = args[0];
        final String argRight = args[1];

        final idLeft = resolveId(argLeft);
        if (idLeft == null) return;
        final leftSnapshot = await readSnapshot(context, idLeft, password: finalPassword);
        if (leftSnapshot == null) return;
        leftFiles = await _decodeSnapshotFiles(leftSnapshot);
        leftLabel = 'snapshot:$idLeft';

        if (argRight == '.') {
          rightFiles = await _readCurrentProjectFiles();
          rightLabel = 'working-tree (live)';
        } else {
          final idRight = resolveId(argRight);
          if (idRight == null) return;
          final rightSnapshot = await readSnapshot(context, idRight, password: finalPassword);
          if (rightSnapshot == null) return;
          rightFiles = await _decodeSnapshotFiles(rightSnapshot);
          rightLabel = 'snapshot:$idRight';
        }
      } 
      else {
        print('❌ Usage: vcs diff [id_or_track_1] [id_or_track_2 | .]'.red);
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

  Future<void> push(
    String message, {
    String? author,
    String? track,
    String? password,
    String? overrideSourcePath, 
    bool skipConfirm = false,
    bool amend = false,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    Directory workingDir = _cwd; 
    String targetTrackName = track ?? context.remoteMeta.activeTrack;

    final sessionFile = File(p.join(context.remoteRepoDir.path, 'session.json'));
    
    if (overrideSourcePath != null) {
      workingDir = Directory(overrideSourcePath);
    } else if (sessionFile.existsSync()) {
      try {
        final sessionData = jsonDecode(await sessionFile.readAsString());
        workingDir = Directory(sessionData['shadow_path']);
        targetTrackName = track ?? sessionData['active_shadow_track'];
        if (!skipConfirm) print('🔍 ${"Shadow Session detected:".cyan} Pushing from ${workingDir.path}');
      } catch (_) {}
    }

    final trackData = context.remoteMeta.tracks[targetTrackName];
    if (trackData == null) {
      print('❌ Track "$targetTrackName" does not exist.');
      return;
    }

    if (amend) {
      if (trackData.logs.isEmpty) {
        print('❌ Cannot use --amend: Track "$targetTrackName" has no history.');
        return;
      }

      final lastId = trackData.logs.first.id;
      final hasTags = context.remoteMeta.tags.values.contains(lastId);
      
      if (hasTags) {
        final tagNames = context.remoteMeta.tags.entries
            .where((e) => e.value == lastId)
            .map((e) => e.key)
            .join(', ');
            
        print('❌ ${"Cannot amend:".red} Latest snapshot has tags: ${tagNames.magenta}');
        print('ℹ️ Please remove the tags before amending or create a new snapshot.');
        return;
      }
    }

    final finalPassword = password ?? askPassword();
    if (finalPassword == null || finalPassword.isEmpty) {
      print('❌ Password required for encryption.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      final currentFingerprint = await buildFingerprint(workingDir);

      Map<String, String> lastFingerprint = {};
      if (trackData.logs.isNotEmpty) {
        final baseEntryIndex = (amend && trackData.logs.length > 1) ? 1 : 0;
        final baseEntry = trackData.logs[baseEntryIndex];
        try {
          final lastSnapshot = await readSnapshot(
            context,
            baseEntry.id,
            password: finalPassword,
          );
          if (lastSnapshot != null) {
            lastFingerprint = Map<String, String>.from(lastSnapshot.fingerprint);
          }
        } catch (e) {
          print('⚠️ Warning: Error reading base snapshot for diff.');
        }
      }

      final changes = diffFingerprints(lastFingerprint, currentFingerprint);

      if (changes.isEmpty && trackData.logs.isNotEmpty && !amend) {
        print('ℹ️ No changes to save in track "$targetTrackName".');
        return;
      }

      if (!skipConfirm) {
        print('\n${(amend ? '--- 🛠️ Amending Last Snapshot ---' : '--- Snapshot Preview ---').cyan}');
        print('${'Source:'.padRight(12)} ${workingDir.path}');
        print('${'Track:'.padRight(12)} $targetTrackName');
        print('${'Message:'.padRight(12)} $message');
        
        int added = 0, modified = 0, deleted = 0;
        for (var change in changes) {
          final tag = change.toTag();
          if (tag.startsWith('+')) { added++; print('  ${"[+]".green} ${change.path}'); }
          else if (tag.startsWith('-')) { deleted++; print('  ${"[-]".red} ${change.path}'); }
          else { modified++; print('  ${"[~]".yellow} ${change.path}'); }
        }

        print('\nSummary: ${added.toString().green} added, ${modified.toString().yellow} modified, ${deleted.toString().red} deleted.');
        
        stdout.write('\nDo you want to proceed? (y/N): ');
        if ((stdin.readLineSync()?.trim().toLowerCase() ?? 'n') != 'y') return;
      }

      if (amend) {
        final oldSnapshot = trackData.logs.first;
        final oldFile = File(p.join(context.remoteRepoDir.path, 'snapshots', oldSnapshot.fileName));
        if (oldFile.existsSync()) {
          await oldFile.delete();
        }
      }

      print('📦 Packing and encrypting...');
      final zipBytes = await _createZipFromCurrentProject(sourcePath: workingDir);
      
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

      final finalFile = File(p.join(snapshotsDir.path, '$snapshotId.vcs'));

      String? fileHash;
      try {
        await finalFile.writeAsBytes(encrypted, flush: true);
        fileHash = sha256.convert(encrypted).toString();
      } catch (e) {
        print('❌ Error writing snapshot: $e');
        return;
      }

      final List<SnapshotNote> existingNotes = amend ? trackData.logs.first.notes : [];

      final entry = SnapshotLogEntry(
        id: snapshotId,
        message: message,
        author: author,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        fileName: '$snapshotId.vcs',
        changeSummary: changes.map((e) => e.toTag()).toList(),
        hash: fileHash,
        notes: existingNotes,
      );

      final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
      
      if (amend) {
        final newLogs = List<SnapshotLogEntry>.from(trackData.logs);
        newLogs[0] = entry;
        updatedTracks[targetTrackName] = TrackState(logs: newLogs);
      } else {
        updatedTracks[targetTrackName] = TrackState(logs: [entry, ...trackData.logs]);
      }

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        tracks: updatedTracks,
      );

      final metaFile = File(p.join(context.remoteRepoDir.path, 'meta.json'));
      if (metaFile.existsSync()) {
        await metaFile.copy(p.join(context.remoteRepoDir.path, 'meta.json.bak'));
      }

      await _atomicWriteString(
        metaFile, 
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson())
      );

      print('✅ Snapshot ${amend ? "amended" : "saved"} successfully in track ${targetTrackName.cyan}.');
    });
  }

  Future<void> _atomicWriteString(File file, String content) async {
    if (await file.exists()) {
      final int size = await file.length();
      if (size > 0) {
        final String path = file.path;

        final f3 = File('$path.bak3');
        final f2 = File('$path.bak2');
        final f1 = File('$path.bak1');

        if (await f2.exists()) await f2.copy(f3.path);
        if (await f1.exists()) await f1.copy(f2.path);
        await file.copy(f1.path);

        await file.copy('$path.bak'); 
      }
    }

    final temp = File('${file.path}.tmp');
    
    try {
      await temp.writeAsString(content, flush: true);

      if (await temp.length() > 0) {
        try {
          await temp.rename(file.path);
        } catch (_) {
          await temp.copy(file.path);
          await temp.delete();
        }
      } else {
        throw Exception("Temporal file is empty, aborting write to prevent corruption.");
      }
    } catch (e) {
      print('❌ ${"Critical Error saving metadata:".red} $e');
    }
  }

  String _renderMarkdown(String text) {
    if (text.isEmpty) return text;

    String rendered = text.replaceAllMapped(RegExp(r'```[a-z]*\n([\s\S]*?)```'), (m) {
      final content = m.group(1)?.trim() ?? "";
      return content.split('\n').map((l) => '    ┃ '.italic + l).join('\n');
    });

    List<String> lines = rendered.split('\n');
    List<String> result = [];
    String? activeAdmonition;

    for (var line in lines) {
      String processed = line;
      String trimmed = line.trim();

      processed = processed.replaceAllMapped(
        RegExp(r'!\[.*?\]\(https:\/\/img\.shields\.io\/badge\/(.*?)-(.*?)-(.*?)(?:\?.*?)?\)'), 
        (m) {
          String label = (m.group(1) ?? "").replaceAll('--', '-').replaceAll('_', ' ');
          String message = (m.group(2) ?? "").replaceAll('--', '-').replaceAll('_', ' ');
          String color = (m.group(3) ?? "blue").split('?')[0].toUpperCase();
          return _renderBadge('[[ $color: $label $message ]]');
        }
      );

      if (trimmed.startsWith('> [!')) {
        final match = RegExp(r'> \[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]', caseSensitive: false).firstMatch(trimmed);
        if (match != null) {
          activeAdmonition = match.group(1)!.toUpperCase();
          final icons = {'NOTE': 'ℹ', 'TIP': '💡', 'IMPORTANT': '📢', 'WARNING': '⚠️', 'CAUTION': '🛑'};
          final head = '  ${icons[activeAdmonition]} $activeAdmonition';
          
          if (activeAdmonition == 'IMPORTANT') result.add(head.cyan.bold);
          else if (activeAdmonition == 'WARNING') result.add(head.yellow.bold);
          else if (activeAdmonition == 'CAUTION') result.add(head.red.bold);
          else result.add(head.blue.bold);
          continue;
        }
      }

      if (trimmed.startsWith('>')) {
        String content = trimmed.substring(1).trimLeft();
        if (content.isNotEmpty) {
          if (activeAdmonition == 'IMPORTANT') {
            result.add('    ${content.cyan}');
          } else if (activeAdmonition == 'WARNING' || activeAdmonition == 'CAUTION') {
            result.add('    ${content.yellow}');
          } else if (activeAdmonition == 'TIP') {
            result.add('    ${content.green}');
          } else if (activeAdmonition == 'NOTE') {
            result.add('    ${content.blue}');
          } else {
            result.add('  ${content.grey.italic}');
          }
        }
        continue;
      }

      if (activeAdmonition != null && trimmed.startsWith('>')) {
        String content = trimmed.substring(1).trimLeft();
        if (content.isNotEmpty) {
          if (activeAdmonition == 'IMPORTANT') result.add('    ${content.cyan}');
          else if (activeAdmonition == 'WARNING' || activeAdmonition == 'CAUTION') result.add('    ${content.yellow}');
          else result.add('    ${content.blue}');
        }
        continue;
      }

      if (!trimmed.startsWith('>') && trimmed.isNotEmpty) activeAdmonition = null;

      if (trimmed.startsWith('# ')) {
        String content = trimmed.replaceFirst('# ', '');
        int bStart = content.indexOf('[[');
        if (bStart != -1) {
          processed = '  ' + content.substring(0, bStart).cyan.bold.underline + ' ' + _renderBadge(content.substring(bStart));
        } else {
          processed = '  ' + content.cyan.bold.underline;
        }
      } 
      else if (trimmed.startsWith('## ')) {
        processed = '\n  ' + trimmed.replaceFirst('## ', '').bold + '\n  ' + ('─' * 45).italic;
      } 
      else if (trimmed.startsWith('### ')) {
        processed = '    ' + trimmed.replaceFirst('### ', '').yellow.bold;
      }

      processed = processed.replaceAllMapped(RegExp(r'\[\[\s?(?:(\w+):)?\s?([^\]]+)\s?\]\]'), (m) => _renderBadge(m.group(0)!));

      if (trimmed.startsWith('• ') || trimmed.startsWith('- ')) {
        processed = processed.replaceFirst(RegExp(r'^[•-] '), '  • '.cyan);
      }
      if (trimmed == '---') {
        processed = '  ' + ('━' * 50).italic;
      }

      processed = processed.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => (m.group(1) ?? "").green);
      processed = processed.replaceAllMapped(RegExp(r'\*\*(.*?)\*\*'), (m) => (m.group(1) ?? "").bold);
      processed = processed.replaceAllMapped(RegExp(r'(https?:\/\/[^\s]+)'), (m) => (m.group(1) ?? "").blue.underline);

      if (!trimmed.startsWith('> [!') && !(activeAdmonition != null && trimmed.startsWith('>'))) {
        result.add(processed);
      }
    }

    return result.join('\n');
  }

  String _renderBadge(String rawBadge) {
    final match = RegExp(r'\[\[\s?(?:(\w+):)?\s?([^\]]+)\s?\]\]').firstMatch(rawBadge);
    if (match == null) return rawBadge;
    
    final colorKey = (match.group(1) ?? 'CYAN').toUpperCase();
    final label = (match.group(2) ?? "").trim();
    final badgeText = ' $label '.bold;

    switch (colorKey) {
      case 'RED': case 'CRITICAL': case 'ORANGE': return badgeText.white.onRed;
      case 'GREEN': case 'SUCCESS': return badgeText.black.onGreen;
      case 'YELLOW': return badgeText.black.onYellow;
      case 'BLUE': return badgeText.white.onBlue;
      case 'MAGENTA': return badgeText.white.onMagenta;
      default: return badgeText.black.onCyan;
    }
  }

  Future<void> log({
    LogViewMode mode = LogViewMode.summary, 
    String? track, 
    bool showGraph = false
  }) async {
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

    final Map<String, List<String>> idToTags = {};
    context.remoteMeta.tags.forEach((tagName, snapshotId) {
      idToTags.putIfAbsent(snapshotId, () => []).add(tagName);
    });

    print('\n📜 ${"Snapshot history".cyan} [Track: ${targetTrackName.cyan}]');
    print('═' * 60);

    final logs = trackData.logs; 
    final total = logs.length;

    for (var i = total - 1; i >= 0; i--) {
      final entry = logs[i];
      final createdAt = _formatDateForList(entry.createdAt);
      final author = entry.author ?? '-';
      final isLatest = i == 0; 
      final isFirstInTerminal = i == total - 1;
      final visualIndex = total - 1 - i;
      final counts = countChanges(entry.changeSummary);
      
      final String node = isLatest ? ' o '.cyan : ' * '.yellow;
      final String pipe = isFirstInTerminal ? '   ' : ' | '.grey;
      final String prefix = showGraph ? node : '';
      final String subPrefix = showGraph ? pipe : '';

      String tagLabel = '';
      if (idToTags.containsKey(entry.id)) {
        tagLabel = idToTags[entry.id]!.map((t) => '🏷️ $t'.magenta).join(' ');
        tagLabel = ' ($tagLabel)';
      }

      print(
        '$prefix[${visualIndex.toString().padLeft(2, '0')}] '
        '${entry.id.green}'
        '${isLatest ? " ${"(latest)".cyan}" : ""}'
        '$tagLabel',
      );

      print('$subPrefix     ${"Date:".yellow.padRight(10)} $createdAt');
      print('$subPrefix     ${"Author:".yellow.padRight(10)} $author');

      final msgLines = _renderMarkdown(entry.message).split('\n');
      for (var j = 0; j < msgLines.length; j++) {
        final label = j == 0 ? "Message:".yellow.padRight(10) : " ".padRight(10);
        print('$subPrefix     $label ${msgLines[j]}');
      }

      if (entry.notes.isNotEmpty) {
        for (var n = 0; n < entry.notes.length; n++) {
          final note = entry.notes[n];
          final noteAuthor = note.author != null ? ' (@${note.author})' : '';
          final noteDate = _formatDateForList(note.createdAt);
          
          final label = n == 0 ? "Notes:".magenta.padRight(10) : " ".padRight(10);
          print('$subPrefix     $label ${"📝 ${note.text}".italic}${" $noteDate$noteAuthor".grey}');
        }
      }

      switch (mode) {
        case LogViewMode.summary:
          if (entry.changeSummary.isEmpty) {
            print('$subPrefix     ${"Changes:".yellow.padRight(10)} ${"(none)".red}');
          } else {
            print(
              '$subPrefix     ${"Changes:".yellow.padRight(10)} '
              '${counts.total.toString().green} file(s) '
              '(${'+${counts.added}'.green} ${'~${counts.modified}'.yellow} ${'-${counts.deleted}'.red})',
            );
          }
          break;

        case LogViewMode.standard:
          if (entry.changeSummary.isEmpty) {
            print('$subPrefix     ${"Changes:".yellow.padRight(10)} ${"(none)".red}');
          } else {
            print(
              '$subPrefix     ${"Changes:".yellow.padRight(10)} '
              '${counts.total.toString().green} file(s) '
              '(${'+${counts.added}'.green} ${'~${counts.modified}'.yellow} ${'-${counts.deleted}'.red})',
            );

            final preview = entry.changeSummary.take(5).toList();
            for (final c in preview) {
              if (c.startsWith('[N]')) {
                print('$subPrefix       ${c.green}');
              } else if (c.startsWith('[M]')) {
                print('$subPrefix       ${c.yellow}');
              } else if (c.startsWith('[D]')) {
                print('$subPrefix       ${c.red}');
              } else {
                print('$subPrefix       $c');
              }
            }

            final remaining = entry.changeSummary.length - preview.length;
            if (remaining > 0) {
              print('$subPrefix       ${"... and $remaining more change(s)".yellow}');
            }
          }
          break;

        case LogViewMode.full:
          if (entry.changeSummary.isEmpty) {
            print('$subPrefix     ${"Changes:".yellow.padRight(10)} ${"(none)".red}');
          } else {
            print('$subPrefix     ${"Changes:".yellow.padRight(10)}');
            for (final c in entry.changeSummary) {
              if (c.startsWith('[N]')) {
                print('$subPrefix       ${c.green}');
              } else if (c.startsWith('[M]')) {
                print('$subPrefix       ${c.yellow}');
              } else if (c.startsWith('[D]')) {
                print('$subPrefix       ${c.red}');
              } else {
                print('$subPrefix       $c');
              }
            }
          }
          break;
      }

      if (i != 0) { 
        if (showGraph) {
          print(' | '.grey);
        } else {
          print('─' * 60);
        }
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

  Future<void> showSnapshot(String? snapshotId, {String? track}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    if (trackData == null) {
      print('❌ ${"Track not found:".red} $targetTrackName');
      return;
    }

    if (trackData.logs.isEmpty) {
      print('ℹ️  ${"No snapshots available in track".yellow} ${targetTrackName.cyan}');
      return;
    }

    SnapshotLogEntry? entry;
    if (snapshotId == null || snapshotId.isEmpty) {
      entry = trackData.logs.first;
      print('ℹ️  ${"No ID provided. Showing latest snapshot from".grey} ${targetTrackName.cyan}');
    } else {
      for (final item in trackData.logs) {
        if (item.id == snapshotId) {
          entry = item;
          break;
        }
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

    void check(bool ok, String label, {String? details, bool isInfo = false}) {
      if (ok) {
        okCount++;
        print('  ${"✔".green} ${label.green}');
      } else {
        if (isInfo) {
          print('  ${"ℹ".blue} ${label.blue}');
        } else {
          warnCount++;
          print('  ${"⚠".yellow} ${label.yellow}');
        }
      }
      if (details != null && details.trim().isNotEmpty) {
        print('      $details');
      }
    }

    print('\n${"Local project".yellow}');
    print('─' * 60);

    final localInitialized = _localRepoFile.existsSync();
    check(localInitialized, 'Local repository metadata', 
      details: localInitialized ? _localRepoFile.path : 'Run "vcs init" to start.');

    final gitignoreExists = _gitignoreFile.existsSync();
    check(gitignoreExists, '.gitignore detected', 
      details: gitignoreExists ? null : 'VCS will snapshot EVERYTHING without a .gitignore.');

    final usb = await findUsbDrive();
    if (usb == null) {
      print('\n${"USB / Remote storage".red}');
      print('─' * 60);
      check(false, 'Drive availability', details: 'No drive with "$driveMarkerFile" found.');
    } else {
      print('\n${"Drive Identity".yellow}');
      print('─' * 60);
      
      final markerFile = File(p.join(usb.path, driveMarkerFile));
      try {
        final lines = await markerFile.readAsLines();
        final markerMap = Map.fromEntries(
          lines.where((l) => l.contains('=')).map((l) => MapEntry(l.split('=')[0], l.split('=')[1]))
        );
        final provisionedBy = markerMap['provisionedBy'];
        final provisionedAt = markerMap['provisionedAt'];

        if (provisionedBy != null && provisionedAt != null) {
          check(true, 'VCS Marker valid', 
            details: 'Linked to host: ${provisionedBy.cyan} (at $provisionedAt)');
        } else {
          check(false, 'Legacy Marker detected', isInfo: true,
            details: 'This drive is v0.1. Run "vcs setup" to upgrade metadata.');
        }
      } catch (e) {
        check(false, 'VCS Marker readable', details: 'Marker file is corrupt or unreadable.');
      }

      final reposDirPath = p.join(usb.path, remoteReposDir);
      final reposDir = Directory(reposDirPath);
      check(reposDir.existsSync(), 'Vault directory structure', details: reposDir.path);

      final aliasMgr = AliasManager(reposDir);
      try {
        await aliasMgr.loadAliases();
        check(true, 'Alias System', details: 'Portable shortcuts are accessible.');
      } catch (e) {
        check(false, 'Alias System', details: 'Error reading vcs_aliases.json');
      }
    }

    if (localInitialized && usb != null) {
      print('\n${"Remote Repository Integrity".yellow}');
      print('─' * 60);

      try {
        final localMetaRaw = jsonDecode(await _localRepoFile.readAsString());
        final repoId = localMetaRaw['repo_id']?.toString() ?? '';
        final remoteRepoDir = Directory(p.join(usb.path, remoteReposDir, repoId));

        if (!remoteRepoDir.existsSync()) {
          check(false, 'Remote repository binding', details: 'Repo ID "$repoId" not found on this drive.');
        } else {
          final metaFile = File(p.join(remoteRepoDir.path, remoteMetaFileName));
          final backupFile = File('${metaFile.path}.bak');
          
          RepoMeta? meta;
          bool restoredFromBackup = false;

          if (!metaFile.existsSync()) {
            if (backupFile.existsSync()) {
              print('  ${"🔧".magenta} Main metadata missing. Attempting rescue from backup...');
              meta = RepoMeta.fromJson(jsonDecode(await backupFile.readAsString()));
              await metaFile.writeAsString(await backupFile.readAsString(), flush: true);
              restoredFromBackup = true;
            }
          } else {
            try {
              meta = RepoMeta.fromJson(jsonDecode(await metaFile.readAsString()));
            } catch (e) {
              if (backupFile.existsSync()) {
                print('  ${"🔧".magenta} Main metadata corrupt. Attempting rescue from backup...');
                meta = RepoMeta.fromJson(jsonDecode(await backupFile.readAsString()));
                await metaFile.writeAsString(await backupFile.readAsString(), flush: true);
                restoredFromBackup = true;
              }
            }
          }

          if (meta == null) {
            check(false, 'Metadata availability', details: 'Critical: Meta file and backup are missing or corrupt.');
          } else {
            check(true, restoredFromBackup ? 'Metadata restored from backup' : 'Metadata sync', 
              details: restoredFromBackup ? 'Disaster recovery successful.' : 'Primary meta file is healthy.');

            final Map<String, String?> expectedHashes = {};
            int totalSnapshots = 0;

            for (var track in meta.tracks.values) {
              for (var entry in track.logs) {
                expectedHashes[entry.fileName] = entry.hash;
                totalSnapshots++;
              }
            }

            check(true, 'Track Consistency', 
              details: '$totalSnapshots snapshots across ${meta.tracks.length} tracks.');

            final snapshotsDir = Directory(p.join(remoteRepoDir.path, 'snapshots'));
            if (snapshotsDir.existsSync()) {
              final List<File> physicalFiles = snapshotsDir.listSync().whereType<File>().toList();
              
              int corruptCount = 0;
              int verifiedCount = 0;
              int legacyCount = 0;

              for (var file in physicalFiles) {
                final name = p.basename(file.path);
                if (name.startsWith('.tmp_') || name == 'vcs_aliases.json') continue;

                if (expectedHashes.containsKey(name)) {
                  final savedHash = expectedHashes[name];
                  if (savedHash != null) {
                    final bytes = await file.readAsBytes();
                    final currentHash = sha256.convert(bytes).toString();
                    
                    if (currentHash != savedHash) {
                      corruptCount++;
                      print('  ${"❌".red} Integrity fail: ${name.grey} (Hash mismatch)');
                    } else {
                      verifiedCount++;
                    }
                  } else {
                    legacyCount++;
                  }
                }
              }

              if (corruptCount > 0) {
                check(false, 'Data Content Health', details: 'Found $corruptCount corrupted snapshot files!');
              } else {
                String healthDetails = 'Verified $verifiedCount files.';
                if (legacyCount > 0) healthDetails += ' ($legacyCount legacy files skipped check).';
                check(true, 'Data Content Health', details: healthDetails);
              }

              final tempFiles = physicalFiles.where((f) => p.basename(f.path).startsWith('.tmp_')).toList();
              check(tempFiles.isEmpty, 'Clean environment', 
                details: tempFiles.isEmpty ? null : 'Found ${tempFiles.length} interrupted transaction files.');

              final orphans = physicalFiles.where((f) {
                final name = p.basename(f.path);
                return !expectedHashes.containsKey(name) && !name.startsWith('.tmp_') && name != 'vcs_aliases.json';
              }).toList();

              if (orphans.isNotEmpty) {
                check(false, 'Storage optimization', 
                  details: 'Found ${orphans.length} orphan files (garbage).');
                
                print('      ${"Potential garbage files:".grey}');
                for (var o in orphans) {
                  final size = (o.lengthSync() / 1024).toStringAsFixed(1);
                  final name = p.basename(o.path);
                  print('      - ${name.grey} ($size KB)');
                }
              } else {
                check(true, 'Storage optimized', details: 'No unlinked snapshots found.');
              }
            }
          }
        }
      } catch (e) {
        check(false, 'Critical Error', details: e.toString());
      }
    }

    print('\n${"Summary".yellow}');
    print('─' * 60);
    print('  ${"OK:".green} $okCount');
    print('  ${"Warnings/Errors:".red} $warnCount');

    if (warnCount == 0) {
      print('\n✨ ${"Everything looks perfect. Your portable vault is healthy.".green.bold}');
    } else {
      print('\n⚠️  ${"Diagnostics found issues. Review the warnings above.".yellow.bold}');
    }
    print('');
  }

  Future<void> stats() async {
    final context = await loadRepoContext();
    if (context == null) return;

    final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
    
    int totalBytes = 0;
    int largestBytes = 0;
    String? largestId, largestTrack;
    int verifiedWithHash = 0;
    final trackSizes = <String, int>{};

    final registeredFiles = <String>{};

    if (snapshotsDir.existsSync()) {
      for (var trackEntry in context.remoteMeta.tracks.entries) {
        int trackTotal = 0;
        for (final entry in trackEntry.value.logs) {
          registeredFiles.add(entry.fileName);
          final file = File(p.join(snapshotsDir.path, entry.fileName));
          
          if (file.existsSync()) {
            final size = file.lengthSync();
            trackTotal += size;
            totalBytes += size;
            
            if (entry.hash != null) verifiedWithHash++;

            if (size > largestBytes) {
              largestBytes = size;
              largestId = entry.id;
              largestTrack = trackEntry.key;
            }
          }
        }
        trackSizes[trackEntry.key] = trackTotal;
      }
    }

    int orphanBytes = 0;
    int orphanCount = 0;
    if (snapshotsDir.existsSync()) {
      for (var f in snapshotsDir.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (!registeredFiles.contains(name) && !name.startsWith('.tmp_') && name != 'vcs_aliases.json') {
          orphanBytes += f.lengthSync();
          orphanCount++;
        }
      }
    }

    print('\n📊 ${" REPOSITORY STATISTICS ".black.onCyan}');
    print('═' * 60);

    print('${"GENERAL INFO".bold.cyan}');
    print('${"Project Name:".yellow.padRight(22)} ${context.remoteMeta.projectName.green}');
    print('${"Active Track:".yellow.padRight(22)} ${context.remoteMeta.activeTrack.magenta.bold}');
    print('${"Format Version:".yellow.padRight(22)} v${context.remoteMeta.formatVersion}');

    print('\n${"STORAGE SUMMARY".bold.cyan}');
    final totalLogs = context.remoteMeta.tracks.values.fold(0, (prev, t) => prev + t.logs.length);
    print('${"Total Snapshots:".yellow.padRight(22)} ${totalLogs.toString().green}');
    print('${"Integrity Coverage:".yellow.padRight(22)} ${((verifiedWithHash / (totalLogs > 0 ? totalLogs : 1)) * 100).toStringAsFixed(1)}% verified');
    print('${"Vault Total Size:".yellow.padRight(22)} ${_formatBytes(totalBytes).green.bold}');
    
    if (totalLogs > 0) {
      print('${"Average Item Size:".yellow.padRight(22)} ${_formatBytes(totalBytes ~/ totalLogs).white}');
      print('${"Largest Snapshot:".yellow.padRight(22)} ${largestId?.green ?? "N/A"} (${_formatBytes(largestBytes)})');
    }

    if (orphanCount > 0) {
      print('${"Unlinked Garbage:".red.padRight(22)} ${_formatBytes(orphanBytes).red} ($orphanCount files)');
      print('  ${"ℹ Tip: Run 'vcs doctor' to see details.".grey}');
    }

    print('\n${"TRACKS BREAKDOWN".bold.cyan}');
    context.remoteMeta.tracks.forEach((name, state) {
      final isActive = name == context.remoteMeta.activeTrack;
      final prefix = isActive ? ' → '.cyan.bold : '   ';
      final size = _formatBytes(trackSizes[name] ?? 0);
      
      print('$prefix${name.padRight(18)} ${state.logs.length.toString().padLeft(3)} logs | ${size.padLeft(10)}');
    });

    print('\n${"TIMELINE".bold.cyan}');
    final allLogs = context.remoteMeta.tracks.values.expand((t) => t.logs).toList();
    if (allLogs.isNotEmpty) {
      allLogs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      print('${"Last Activity:".yellow.padRight(22)} ${_formatDateForList(allLogs.first.createdAt)}');
      print('${"Vault Creation:".yellow.padRight(22)} ${_formatDateForList(allLogs.last.createdAt)}');
    }

    print('═' * 60);
    print('${"Vault Location:".grey} ${context.remoteRepoDir.path.grey}');
    print('');
  }

  Future<void> prune({
    int? keep, 
    int? olderThanDays, 
    bool garbage = false, 
    String? snapshotId
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final referencedFiles = <String>{};
    for (final track in context.remoteMeta.tracks.values) {
      for (final entry in track.logs) {
        referencedFiles.add(entry.fileName);
      }
    }

    final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
    final toDeleteFiles = <File>[];
    final activeTrackName = context.remoteMeta.activeTrack;
    final logs = List<SnapshotLogEntry>.from(context.remoteMeta.tracks[activeTrackName]?.logs ?? []);

    if (garbage && snapshotsDir.existsSync()) {
      print('🔍 ${"Scanning for garbage files...".grey}');
      final physicalFiles = snapshotsDir.listSync().whereType<File>();
      
      for (final file in physicalFiles) {
        final name = p.basename(file.path);
        if (name.startsWith('.tmp_') || !referencedFiles.contains(name)) {
          toDeleteFiles.add(file);
        }
      }
    }

    final toDeleteFromLogs = <SnapshotLogEntry>[];

    if (snapshotId != null) {
      print('🎯 ${"Targeting specific snapshot ID: $snapshotId".cyan}');
      try {
        final targetEntry = logs.firstWhere((e) => e.id == snapshotId);
        toDeleteFromLogs.add(targetEntry);
        
        final f = File(p.join(snapshotsDir.path, targetEntry.fileName));
        if (f.existsSync()) toDeleteFiles.add(f);
      } catch (_) {
        print('❌ ${"Error:".red} Snapshot ID $snapshotId not found in active track.');
        return;
      }
    } 

    else if (keep != null || olderThanDays != null) {
      if (logs.isEmpty) {
        print('ℹ️ No snapshots in active track to prune by history.');
      } else {
        final now = DateTime.now().toUtc();
        final toDeleteIds = <String>{};

        if (olderThanDays != null) {
          for (final entry in logs) {
            final created = DateTime.tryParse(entry.createdAt)?.toUtc();
            if (created != null && now.difference(created).inDays > olderThanDays) {
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

        for (var entry in logs) {
          if (toDeleteIds.contains(entry.id)) {
            toDeleteFromLogs.add(entry);
            final f = File(p.join(snapshotsDir.path, entry.fileName));
            if (f.existsSync()) toDeleteFiles.add(f);
          }
        }
      }
    }

    if (toDeleteFiles.isEmpty && toDeleteFromLogs.isEmpty) {
      print('✨ ${"Everything is clean. Nothing to prune.".green}');
      return;
    }

    print('\n${"PREPARING CLEANUP:".bold}');
    if (toDeleteFromLogs.isNotEmpty) {
      print('📦 Snapshots to remove from history: ${toDeleteFromLogs.length}');
      for (var entry in toDeleteFromLogs) {
        print('   - ${entry.id.grey} (${entry.message})');
      }
    }
    if (toDeleteFiles.isNotEmpty) {
      print('🗑️  Physical files to delete: ${toDeleteFiles.length}');
    }

    stdout.write('\nProceed with deletion? (y/N): ');
    if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') return;

    await _withLock(context.remoteRepoDir, () async {
      for (final file in toDeleteFiles) {
        try {
          if (await file.exists()) await file.delete();
        } catch (e) {
          print('⚠️ Could not delete ${file.path}: $e');
        }
      }

      if (toDeleteFromLogs.isNotEmpty) {
        final toDeleteIds = toDeleteFromLogs.map((e) => e.id).toSet();
        final remaining = logs.where((e) => !toDeleteIds.contains(e.id)).toList();

        final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
        updatedTracks[activeTrackName] = TrackState(logs: remaining);

        final updatedMeta = context.remoteMeta.copyWith(
          updatedAt: DateTime.now().toUtc().toIso8601String(),
          tracks: updatedTracks,
        );

        await _atomicWriteString(
          File(p.join(context.remoteRepoDir.path, remoteMetaFileName)),
          const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
        );
      }

      print('\n✅ ${"Cleanup complete!".green.bold}');
      if (toDeleteFiles.isNotEmpty) {
        print('🗑️  Freed storage for ${toDeleteFiles.length} files.');
      }
    });
  }

  Future<void> pull({
    String? track, 
    String? snapshotId, 
    String? password, 
    bool dryRun = false,
  }) async {
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

    String finalSnapshotId = snapshotId ?? trackData.logs.first.id;
    bool isTag = false;

    if (snapshotId != null && context.remoteMeta.tags.containsKey(snapshotId)) {
      final resolvedId = context.remoteMeta.tags[snapshotId]!;
      print('🏷️  Tag detected: ${snapshotId.cyan} -> Resolving to $resolvedId');
      finalSnapshotId = resolvedId;
      isTag = true;
    }

    final entry = trackData.logs.firstWhere(
      (e) => e.id == finalSnapshotId,
      orElse: () => SnapshotLogEntry(id: '', message: '', createdAt: '', fileName: '', author: '', changeSummary: []),
    );

    if (entry.id.isEmpty) {
      final errorMsg = isTag 
        ? '❌ The tag "$snapshotId" points to a snapshot ID ($finalSnapshotId) that no longer exists.'
        : '❌ Snapshot ID "$finalSnapshotId" not found in track "$targetTrackName".';
      print(errorMsg);
      return;
    }

    final headerLabel = dryRun ? '--- PULL DRY RUN (PREVIEW) ---' : '--- PULL/RESTORE PREVIEW ---';
    print('\n${headerLabel.black.onCyan}');
    print('${'Source Track:'.padRight(15)} $targetTrackName');
    
    if (isTag) {
      print('${'Active Tag:'.padRight(15)} ${snapshotId?.cyan}');
    }
    
    print('${'Snapshot ID:'.padRight(15)} ${entry.id.green}');
    print('${'Message:'.padRight(15)} ${entry.message.yellow}');
    print('${'Author:'.padRight(15)} ${entry.author ?? 'Unknown'}');
    print('');

    final snapshotFile = File(p.join(context.remoteRepoDir.path, 'snapshots', entry.fileName));
    
    if (!snapshotFile.existsSync()) {
      print('❌ ${"CRITICAL:".red} Snapshot file missing at ${snapshotFile.path.grey}');
      return;
    }

    if (entry.hash != null) {
      stdout.write('🛡️  Verifying snapshot integrity... ');
      final bytes = await snapshotFile.readAsBytes();
      final currentHash = sha256.convert(bytes).toString();

      if (currentHash != entry.hash) {
        print('\n\n❌ ${'INTEGRITY CHECK FAILED'.red.bold}');
        print('The file on the USB has been corrupted or tampered with.');
        print('Expected: ${entry.hash?.grey}');
        print('Actual:   ${currentHash.red}');
        print('\n🚫 Pull aborted to prevent restoring corrupted data.');
        return;
      }
      print('${"OK".green}');
    }

    if (entry.changeSummary.isEmpty) {
      print('   ${"(No file changes recorded)".grey.italic}');
    } else {
      for (final c in entry.changeSummary) {
        if (c.startsWith('[N]')) print('   ${'[+]'.green} ${c.substring(3).trim()}');
        else if (c.startsWith('[M]')) print('   ${'[~]'.yellow} ${c.substring(3).trim()}');
        else if (c.startsWith('[D]')) print('   ${'[-]'.red} ${c.substring(3).trim()}');
        else print('   $c');
      }
    }

    if (dryRun) {
      print('\n${'ℹ️  INFO:'.cyan} Dry run mode enabled. No files were touched.');
      print('Remove ${'--dry-run'.bold} to apply these changes to your directory.\n');
      return;
    }

    print('\n${'⚠️  WARNING:'.red.bold} This will overwrite local files and delete those not present in the snapshot.');
    stdout.write('Proceed with pull? (y/N): ');
    String? confirm = stdin.readLineSync()?.trim().toLowerCase();
    
    if (confirm != 'y' && confirm != 'yes') {
      print('🚫 Pull aborted.');
      return;
    }

    final finalPassword = password ?? askPassword();
    if (finalPassword == null || finalPassword.isEmpty) {
      print('❌ Password required.');
      return;
    }

    print('\n📥 Processing snapshot ${finalSnapshotId.green}...');
    
    try {
      final snapshot = await readSnapshot(context, finalSnapshotId, password: finalPassword);
      if (snapshot == null) {
        print('❌ Failed to read or decrypt snapshot data. Check your password.');
        return;
      }

      final filesInSnapshot = await _decodeSnapshotFiles(snapshot);
      int restoredCount = 0;
      int deletedCount = 0;

      final deletions = entry.changeSummary.where((c) => c.startsWith('[D]'));
      for (final change in deletions) {
        final pathToDelete = change.substring(3).trim();
        final file = File(pathToDelete);
        if (await file.exists()) {
          try {
            await file.delete();
            deletedCount++;
          } catch (e) {
            print('⚠️  Could not delete ${pathToDelete.grey}: $e');
          }
        }
      }

      final totalFiles = filesInSnapshot.length;
      for (final sEntry in filesInSnapshot.entries) {
        final path = sEntry.key;
        final bytes = sEntry.value;
        final file = File(path);

        final directory = Directory(file.parent.path);
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }

        await file.writeAsBytes(bytes, flush: true);
        restoredCount++;

        if (restoredCount % 5 == 0 || restoredCount == totalFiles) {
          final percent = ((restoredCount / totalFiles) * 100).toInt();
          stdout.write('\rRestoring: $percent% ($restoredCount/$totalFiles files)');
        }
      }

      print('\n\n✅ Pull complete!');
      print('   ${restoredCount.toString().green} files updated/restored.');
      if (deletedCount > 0) {
        print('   ${deletedCount.toString().red} files removed as per snapshot.');
      }
      print('');

    } catch (e) {
      print('\n❌ ${'CRITICAL ERROR during pull:'.red} $e');
      print('ℹ️  Suggestion: Verify your drive connection and try pulling again.');
    }
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

    print('\n⚠️  ${"WARNING:".red.bold} This will delete ALL snapshots from ALL tracks.');
    stdout.write('Type the project name "${context.remoteMeta.projectName.green}" to confirm: ');
    
    if (stdin.readLineSync()?.trim() != context.remoteMeta.projectName) {
      print('🚫 Confirmation failed. Aborting.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));

      if (await snapshotsDir.exists()) {
        await snapshotsDir.delete(recursive: true).catchError((e) => print("Note: $e"));
      }
      await snapshotsDir.create(recursive: true);

      final updatedTracks = context.remoteMeta.tracks.map((name, state) {
        return MapEntry(name, TrackState(logs: []));
      });

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        tracks: updatedTracks,
      );

      await _atomicWriteString(
        File(p.join(context.remoteRepoDir.path, remoteMetaFileName)),
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
      );

      print('🗑️  ${"All history wiped successfully.".green}');
    });
  }

  Future<void> purge() async {
    final context = await loadRepoContext();
    if (context == null) return;

    print('\n${'🔥 DANGER ZONE: PURGE REPOSITORY '.black.onRed}');
    print('${'Project:'.yellow} ${context.remoteMeta.projectName}');
    print('${'Vault Path:'.yellow} ${context.remoteRepoDir.path}');
    print('\nThis will ${'PERMANENTLY DELETE'.red.bold}:');
    print('  1. All snapshots and metadata on the USB.');
    print('  2. Local link and settings (${'.vcs/'.cyan}).');
    
    stdout.write('\n⚠️  To confirm, type "${'PURGE'.red}": ');
    if (stdin.readLineSync()?.trim().toUpperCase() != 'PURGE') {
      print('🚫 Purge cancelled.');
      return;
    }

    bool remoteDeleted = false;

    await _withLock(context.remoteRepoDir, () async {
      try {
        if (await context.remoteRepoDir.exists()) {
          await context.remoteRepoDir.delete(recursive: true);
          print('💀 ${'Remote repo deleted from USB.'.green}');
          remoteDeleted = true;
        }
      } catch (e) {
        print('❌ ${'Error deleting remote repo:'.red} $e');
        print('💡 Check if the USB is still connected or a file is open.');
      }
    });

    if (remoteDeleted || !(await context.remoteRepoDir.exists())) {
      try {
        if (await _localMetaDir.exists()) {
          await _localMetaDir.delete(recursive: true);
          print('🗑️  ${'Local .vcs folder removed.'.green}');
        }
      } catch (e) {
        print('❌ ${'Error deleting local metadata:'.red} $e');
        print('Manual action: You can delete ${_localMetaDir.path} manually.');
      }
    } else {
      print('\n⚠️  ${"Purge incomplete:".yellow} Local metadata kept because remote deletion failed.');
    }

    print('\n✨ ${"Process finished.".bold}\n');
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

    bool _isBinary(Uint8List bytes) {
      if (bytes.isEmpty) return false;
      return bytes.take(1024).contains(0);
    }

    if (allPaths.isEmpty) {
      print('ℹ️ ${"No files to compare.".yellow}');
      return;
    }

    final newFiles = <String>[];
    final deletedFiles = <String>[];
    final modifiedFiles = <String>[];
    final binaryModified = <String>{};

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

      if (a != null && b != null && _filesDiffer(a, b)) {
        modifiedFiles.add(path);
        if (_isBinary(a) || _isBinary(b)) {
          binaryModified.add(path);
        }
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

        if (binaryModified.contains(path)) {
          print('  ${"Binary file changes detected. Content diff skipped.".grey}');
          print('─' * 60);
          continue;
        }

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

  Future<Uint8List> _createZipFromCurrentProject({Directory? sourcePath}) async {
    final archive = Archive();
    final Directory targetDir = sourcePath ?? _cwd;

    await for (final entity in targetDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final rel = _normalizeRelativePath(p.relative(entity.path, from: targetDir.path));      
      if (await _isIgnoredPath(rel)) continue;

      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }

    final zip = ZipEncoder().encode(archive);
    return Uint8List.fromList(zip!);
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
    if (remoteExists) {
      print('📡 ${"Fetching remote status...".grey}');
      await _gitFetch(remote);
      
      final status = await _checkRemoteStatus(remote, branch);
      
      if (status == RemoteStatus.ahead) {
        print('\n⚠️  ${"CONFLICT WARNING:".black.onYellow}');
        print('The remote branch "$remote/$branch" has changes that you don\'t have locally.');
        print('If you publish now, the Git push will fail.');
        print('👉 ${"Recommendation:".bold} Run "git pull $remote $branch" before publishing.');
        
        stdout.write('\nDo you want to ignore this and try anyway? (y/N): ');
        if ((stdin.readLineSync() ?? '').toLowerCase() != 'y') return;
        
      } else if (status == RemoteStatus.diverged) {
        print('\n🚨 ${"CRITICAL: BRANCHES HAVE DIVERGED".white.onRed}');
        print('Both your local and remote branches have different new commits.');
        print('Publishing is highly discouraged until you merge.');
        return;
      }
    } else {
      print('ℹ️ ${'Notice:'.yellow} Remote "$remote" not found. The snapshot will be committed locally but not pushed.');
    }

    if (!await _gitWorkingTreeIsClean()) {
      print('📦 ${"Working tree not clean. Auto-stashing changes...".yellow}');
      final timestamp = DateTime.now().toString().split('.')[0];
      await Process.run(
        'git', 
        ['stash', 'push', '--include-untracked', '-m', 'VCS Auto-stash at $timestamp'], 
        runInShell: true
      );
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

    try {
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
          return; 
        }
        print('✅ ${"Security check passed.".green}\n');
      }

      await _gitAddAll();

      final hasChanges = await _gitHasStagedChanges();
      if (!hasChanges) {
        print('ℹ️ No Git changes detected after applying snapshot. Nothing to commit.');
      } else {
        if (confirmAction('Create Git commit now?')) {
          await _gitCommit(commitMessage);

          if (remoteExists) {
            if (confirmAction('Push commit to "$remote/$branch" now?')) {
              try {
                await _gitPush(remote, branch);
                print('✅ Snapshot ${entry.id} published and pushed to Git.');
              } catch (e) {
                print('\n❌ ${"PUSH FAILED:".red}');
                print('The commit was created locally, but couldn\'t be pushed.');
              }
            }
          } else {
            print('✅ Snapshot ${entry.id} published to local Git (no remote configured).');
          }
        }
      }
    } finally {
      final stashList = await Process.run('git', ['stash', 'list'], runInShell: true);
      final output = stashList.stdout.toString();

      if (output.contains('VCS Auto-stash')) {
        print('\n🔄 ${"Restoring your previous local changes...".grey}');
        final popResult = await Process.run('git', ['stash', 'pop'], runInShell: true);
        
        if (popResult.exitCode == 0) {
          print('✅ ${"Workspace successfully restored to its previous state.".green}');
        } else {
          print('⚠️  ${"Note: Local changes restored with some conflicts o warnings.".yellow}');
          print('   Check "git status" to resolve any issues.'.grey);
        }
      }
      print('─' * 60 + '\n');
    }
  }

  Future<void> timeline({String? track, int limit = 15}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrack = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrack];

    if (trackData == null || trackData.logs.isEmpty) {
      print('ℹ️  ${"No snapshots found in track".yellow} "$targetTrack".');
      return;
    }

    print('\n⏳ ${" INTERACTIVE TIMELINE ".black.onMagenta} ${"v0.3.5-Exp".grey}');
    print('Track: ${targetTrack.cyan} | Showing last $limit snapshots');
    print('═' * 60);

    final logsToShow = trackData.logs.take(limit).toList();

    for (var entry in logsToShow) {
      final String sId = entry.id.toString();
      final String shortId = sId.length > 8 ? sId.substring(0, 8) : sId;
      
      final date = DateTime.parse(entry.createdAt).toLocal().toString().substring(5, 16);
      
      String tagLabel = "";
      context.remoteMeta.tags.forEach((tag, id) {
        if (id == sId) tagLabel = ' 🏷️ ${tag.yellow}';
      });

      print(' ${"•".cyan} ${shortId.grey} | $date | ${entry.message.white.bold}$tagLabel');
    }

    print('═' * 60 + '\n');
  }

  Future<RemoteStatus> _checkRemoteStatus(String remote, String branch) async {
    try {
      final local = (await Process.run('git', ['rev-parse', 'HEAD'])).stdout.toString().trim();
      final remoteRef = (await Process.run('git', ['rev-parse', '$remote/$branch'])).stdout.toString().trim();
      
      if (local == remoteRef) return RemoteStatus.synced;
      
      final base = (await Process.run('git', ['merge-base', 'HEAD', '$remote/$branch'])).stdout.toString().trim();
      
      if (base == local) return RemoteStatus.ahead;
      if (base == remoteRef) return RemoteStatus.behind;
      return RemoteStatus.diverged;
    } catch (_) {
      return RemoteStatus.unknown;
    }
  }

  Future<void> _gitFetch(String remote) async {
    await Process.run('git', ['fetch', remote]);
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

    final ignoredPaths = ['.git', '.vcs', '.dart_tool', 'node_modules', 'build', 'bin', 'obj', 'test'];

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
    print('📥 ${"Restoring snapshot directly from memory...".grey}');
    final backupDir = Directory(
      p.join(_localMetaDir.path, 'backups', 'publish_safety_${DateTime.now().millisecondsSinceEpoch}'),
    );

    try {
      await _createTrackedBackup(backupDir);
      
      final currentTracked = await _listTrackedFiles(_cwd);
      final archive = ZipDecoder().decodeBytes(snapshot.zipBytes);

      for (final rel in currentTracked) {
        final file = File(p.join(_cwd.path, rel));
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (e) {
            // silent error
          }
        }
      }

      for (final file in archive) {
        final path = p.join(_cwd.path, file.name);
        if (file.isFile) {
          final outFile = File(path);

          final parentDir = Directory(outFile.parent.path);
          if (!await parentDir.exists()) {
            await parentDir.create(recursive: true);
          }
          
          final data = file.content as List<int>;

          await outFile.writeAsBytes(data, flush: true);
        } else {
          await Directory(path).create(recursive: true);
        }
      }

      print('✅ ${"Working tree updated successfully.".green}');

      if (await backupDir.exists()) {
        try {
          await backupDir.delete(recursive: true);
        } catch (_) {
          print('ℹ️  ${"Safety backup kept at:".grey} ${backupDir.path}');
        }
      }

    } catch (e) {
      print('❌ ${"Restore failed:".red} $e');
      print('⚠️  Attempting recovery from safety backup...');

      try {
        if (await backupDir.exists()) {
          await _copyTrackedFiles(backupDir, _cwd);
          print('✅ Recovery successful.');
        }
      } catch (recoveryError) {
        print('❌ ${"CRITICAL: Recovery failed.".red} Manual recovery needed from: ${backupDir.path}');
      }
      rethrow;
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

  String _resolveTrackName(String input, RepoContext context) {
    final cleanInput = input.trim();
    if (cleanInput == '.') {
      return context.remoteMeta.activeTrack;
    }
    if (context.remoteMeta.tracks.containsKey(cleanInput)) {
      return cleanInput;
    }
    final caseInsensitiveMatch = context.remoteMeta.tracks.keys.firstWhere(
      (k) => k.toLowerCase() == cleanInput.toLowerCase(),
      orElse: () => '',
    );
    if (caseInsensitiveMatch.isNotEmpty) {
      return caseInsensitiveMatch;
    }
    throw Exception('El track "$input" no existe en este repositorio.');
  }

  Future<bool> _hasUnsavedChangesInPath(String path, String trackName, RepoContext context) async {
    final shadowDir = Directory(path);
    if (!shadowDir.existsSync()) return false;

    final trackData = context.remoteMeta.tracks[trackName];
    if (trackData == null || trackData.logs.isEmpty) {
      final entities = await shadowDir.list(recursive: true).toList();
      return entities.whereType<File>().isNotEmpty;
    }

    final lastEntry = trackData.logs.first;

    try {
      final lastSnapshot = await readSnapshot(
        context, 
        lastEntry.id, 
        password: ''
      );

      if (lastSnapshot == null) return true;

      final currentFingerprint = await buildFingerprint(shadowDir);

      final changes = diffFingerprints(lastSnapshot.fingerprint, currentFingerprint);
      
      return changes.isNotEmpty;
    } catch (e) {
      print('⚠️ Error checking for changes in shadow workspace: $e');
      return true;
    }
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

    print('\n🎯 ${" TRACKS MANAGEMENT ".black.onCyan}');
    print('═' * 65);
    
    print(
      '${"ID".padRight(5)} '
      '${"Name".padRight(22)} '
      '${"Snaps".padRight(10)} '
      '${"Author".padRight(12)} '
      '${"Last Date"}'
    );
    print('─' * 65);

    for (var i = 0; i < trackNames.length; i++) {
      final name = trackNames[i];
      final track = context.remoteMeta.tracks[name]!;
      final isActive = name == context.remoteMeta.activeTrack;
      
      String lastAuthor = "---";
      String lastDate = "---";
      
      if (track.logs.isNotEmpty) {
        final latest = track.logs.first;
        lastAuthor = latest.author ?? "Unknown";
        if (lastAuthor.length > 11) lastAuthor = "${lastAuthor.substring(0, 8)}...";
        lastDate = latest.createdAt.split('T').first; 
      }

      final String idPart = '[${i.toString().padLeft(2, '0')}]'.grey;
      final String namePart = name.padRight(22).green;
      final String snapsPart = track.logs.length.toString().padRight(10);
      final String authorPart = lastAuthor.padRight(12).grey;
      final String datePart = lastDate.grey;
      final String activeIndicator = isActive ? " ${"(active)".cyan}" : "";
      
      print('$idPart $namePart $snapsPart $authorPart $datePart$activeIndicator');
    }

    print('═' * 65);
    print('💡 ${"Tip:".yellow} Use indices (e.g., "vcs track switch 01") for faster navigation.');
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

  Future<void> trackSwitch(String input, {String? password, bool webRestore = false}) async {
    const String advisor = '''
    > [[ NOTE ]]
    > VCS only manages file integrity. 👉 Remember to initialize your environment (e.g., "pub get", "npm install") in the new window.
    ''';
    final context = await loadRepoContext();
    if (context == null) return;

    final sessionFile = File(p.join(context.remoteRepoDir.path, 'session.json'));
    
    if (sessionFile.existsSync()) {
      try {
        final sessionData = jsonDecode(sessionFile.readAsStringSync());
        final String shadowTrack = sessionData['active_shadow_track'];
        final String shadowPath = sessionData['shadow_path'];

        final hasChanges = await _hasUnsavedChangesInPath(shadowPath, shadowTrack, context);
        if (hasChanges) {
          print('⚠️  ${"Unsaved changes".yellow} found in shadow workspace.');
          if (!webRestore && confirmAction('Do you want to PUSH changes before switching?')) {
            await push("Auto-save before switching", overrideSourcePath: shadowPath, track: shadowTrack, skipConfirm: true);
          }
        }

        final directory = Directory(shadowPath);
        if (directory.existsSync()) {
          try { await directory.delete(recursive: true); } catch (e) {}
        }
        await sessionFile.delete();
      } catch (e) {
        print('⚠️ Error closing session: $e');
      }
    }

    String targetTrackName = _resolveTrackName(input, context);

    final updatedMeta = context.remoteMeta.copyWith(
      activeTrack: targetTrackName,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final metaFile = File(p.join(context.remoteRepoDir.path, 'meta.json'));
    await _atomicWriteString(metaFile, jsonEncode(updatedMeta.toJson()));

    if (targetTrackName == 'main') {
      print('🏠 ${"Back to main track.".green}');
      return;
    }

    print('🧪 Preparing shadow workspace for: $targetTrackName');
    final shadowPath = p.join(Directory.current.path, '.vcs', 'shadow_$targetTrackName');
    final shadowDir = Directory(shadowPath);
    
    if (!shadowDir.existsSync()) await shadowDir.create(recursive: true);

    final trackData = context.remoteMeta.tracks[targetTrackName];
    if (trackData != null && trackData.logs.isNotEmpty) {
      
      String? effectivePassword = password;
      if (effectivePassword == null || effectivePassword.isEmpty) {
        effectivePassword = askPassword();
      }

      if (effectivePassword == null || effectivePassword.isEmpty) {
        print('❌ Password required.');
        return; 
      }

      print('📥 Extracting last snapshot to LOCAL storage...');
      
      final lastSnapshot = await readSnapshot(
        context, 
        trackData.logs.first.id, 
        password: effectivePassword, 
      );

      if (lastSnapshot != null) {
        final archive = ZipDecoder().decodeBytes(lastSnapshot.zipBytes);
        for (final file in archive) {
          if (file.isFile) {
            final outFile = File(p.join(shadowPath, file.name));
            await outFile.create(recursive: true);
            await outFile.writeAsBytes(file.content as List<int>);
          }
        }
        print('✅ Content restored locally.');
      } else {
        print('❌ Wrong password.');
        return;
      }
    }

    final newSession = {
      'active_shadow_track': targetTrackName,
      'shadow_path': shadowPath,
      'start_time': DateTime.now().toUtc().toIso8601String(),
    };
    await sessionFile.writeAsString(jsonEncode(newSession));

    print('💻 Opening VS Code instance...');
    try {
      await Process.run('code', [shadowPath], runInShell: true);
    } catch (e) {
      print('⚠️ Could not launch VS Code. Path: $shadowPath');
    }

    print('🚀 Shadow workspace ready at: ${shadowPath.cyan}');
    print({"ℹ️ NOTE".cyan});
    print({"VCS only manages file integrity. 👉 Remember to initialize your environment (e.g., 'pub get', 'npm install') in the new window.".cyan});
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
        * { box-sizing: border-box; transition: background 0.2s, border-color 0.2s; }
        body { 
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; 
          background: var(--bg); color: var(--text); margin: 0; display: flex; height: 100vh; overflow: hidden;
        }
        
        .sidebar { 
          width: 300px; border-right: 1px solid var(--border); padding: 25px; 
          display: flex; flex-direction: column; background: #010409; z-index: 10;
        }
        .stats-card { background: var(--card); border: 1px solid var(--border); padding: 12px; border-radius: 8px; margin-bottom: 10px; }
        .stat-label { font-size: 10px; text-transform: uppercase; color: var(--text-dim); letter-spacing: 1px; }
        .stat-value { font-size: 14px; font-weight: bold; color: var(--accent); display: block; margin-top: 2px; }

        .actions-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 20px; }
        .btn-action { 
          background: var(--card); border: 1px solid var(--border); color: var(--text); padding: 12px;
          border-radius: 6px; cursor: pointer; font-size: 12px; font-weight: 600;
          display: flex; flex-direction: column; align-items: center; gap: 4px;
        }
        .btn-action:hover { border-color: var(--accent); background: #1c2128; transform: translateY(-1px); }
        .btn-action:active { transform: translateY(0); }

        .workspace { flex: 1; display: flex; flex-direction: column; height: 100vh; position: relative; }
        .main-content { flex: 1; overflow-y: auto; padding: 40px; scroll-behavior: smooth; }
        
        .terminal-container {
          height: 280px; background: var(--term-bg); border-top: 1px solid var(--border);
          display: flex; flex-direction: column; font-family: 'SFMono-Regular', Consolas, monospace;
          box-shadow: 0 -10px 30px rgba(0,0,0,0.5);
        }
        .terminal-output { flex: 1; overflow-y: auto; padding: 15px; font-size: 13px; line-height: 1.6; color: #d1d5da; }
        .terminal-output div { white-space: pre-wrap; word-break: break-all; margin-bottom: 2px; }
        .terminal-input-area { 
          display: flex; align-items: center; padding: 12px 15px; background: #090c10; border-top: 1px solid #21262d;
        }
        .prompt { color: var(--added); margin-right: 10px; font-weight: bold; user-select: none; }
        .cmd-input { 
          flex: 1; background: transparent; border: none; color: white; font-family: inherit; font-size: 14px; outline: none;
        }

        .snapshot-card { 
          background: var(--card); border: 1px solid var(--border); padding: 15px; 
          margin-bottom: 10px; border-radius: 8px; cursor: pointer; 
          display: flex; justify-content: space-between; align-items: center;
        }
        .snapshot-card:hover { border-color: var(--accent); background: #1c2128; box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
        
        #codeViewer { 
          display: none; position: fixed; inset: 20px; background: var(--term-bg); border: 1px solid var(--border);
          border-radius: 12px; z-index: 1000; flex-direction: column; box-shadow: 0 20px 50px rgba(0,0,0,0.8);
        }

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
          padding: 0 15px;
          font-size: 12px; 
          min-height: 1.5em;
          line-height: 1.5;
          display: block;
        }
        .diff-line.add { background-color: rgba(46, 160, 67, 0.15); color: #7ee787; border-left: 3px solid #3fb950; }
        .diff-line.del { background-color: rgba(248, 81, 73, 0.15); color: #ff7b72; border-left: 3px solid #f85149; }
        .diff-line.empty { background-color: rgba(255, 255, 255, 0.02); }

        #passwordModal { 
          display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.8); 
          backdrop-filter: blur(8px); justify-content: center; align-items: center; z-index: 2000;
        }
        .modal-content { 
          background: var(--card); padding: 30px; border-radius: 12px; border: 1px solid var(--border); 
          width: 380px; text-align: center; box-shadow: 0 10px 40px rgba(0,0,0,0.5);
        }
        .modal-content input { 
          width: 100%; padding: 12px; background: var(--bg); border: 1px solid var(--border); 
          color: white; border-radius: 6px; margin: 20px 0; outline: none; font-size: 16px;
        }
        .badge-status { padding: 2px 8px; border-radius: 12px; font-size: 10px; border: 1px solid; font-weight: bold; text-transform: uppercase; }
        .added { color: var(--added); border-color: var(--added); }
        .modified { color: var(--modified); border-color: var(--modified); }
        .deleted { color: var(--deleted); border-color: var(--deleted); }

        .track-select {
          width: 100%; background: transparent; border: none; color: var(--accent); 
          font-size: 14px; font-weight: bold; outline: none; cursor: pointer;
          padding: 0; margin-top: 2px; appearance: none;
        }
        .track-select option { background: var(--card); color: var(--text); }

        /* Loading Animation */
        .loader {
          width: 14px; height: 14px; border: 2px solid var(--text-dim); border-bottom-color: transparent;
          border-radius: 50%; display: inline-block; animation: rotation 1s linear infinite; margin-left: 10px; visibility: hidden;
        }
        @keyframes rotation { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    """;

    final snapshotsHtml = meta.logs.map((log) {
      return """
          <div class="snapshot-card" onclick="openInspector('${log.id}', '${log.message}')">
            <div>
              <div style="font-weight:600; color:#f0f6fc;">${log.message}</div>
              <div style="font-size:12px; color:var(--text-dim); margin-top:4px;">
                <strong style="color:var(--text)">${log.author ?? "Anonymous"}</strong> • ${log.createdAt}
              </div>
            </div>
            <div style="font-family:monospace; font-size:11px; background:#30363d; padding:4px 8px; border-radius:4px; color:var(--accent);">${log.id.substring(0, 8)}</div>
          </div>
        """;
    }).join('');

    final trackOptions = meta.tracks.keys
        .map((t) => '<option value="$t" ${t == meta.activeTrack ? 'selected' : ''}>$t</option>')
        .join('');

    return r"""
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <title>VCS Terminal Dashboard</title>
        <style>""" + css + r"""</style>
      </head>
      <body>
        <div class="sidebar">
          <h2 style="font-size: 18px; margin-bottom: 20px; display:flex; align-items:center; gap:10px;">
            <span style="font-size:24px;">📦</span> Repo Explorer
          </h2>
          
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
            <button class="btn-action" onclick="setCmd('status')"><span>🔍</span>Status</button>
            <button class="btn-action" onclick="setCmd('diff')"><span>🌓</span>Diff</button>
            <button class="btn-action" onclick="setCmd('push \"\" -a ')"><span>📤</span>Push</button>
            <button class="btn-action" onclick="setCmd('pull')"><span>📥</span>Pull</button>
            <button class="btn-action" onclick="setCmd('publish --branch main')"><span>🚀</span>Publish</button>
            <button class="btn-action" onclick="setCmd('doctor')"><span>🩺</span>Doctor</button>
            <button class="btn-action" onclick="executeRaw('help')" style="grid-column: span 2; border-color: var(--warning); color: var(--warning);">❓ Help Guide</button>
          </div>
          
          <div style="margin-top:auto; font-size:10px; color:var(--text-dim); text-align:center;">
            Portable VCS Web v2.1.0
          </div>
        </div>

        <div class="workspace">
          <div class="main-content">
            <div id="viewList">
              <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:30px;">
                <h1 style="font-size:24px; margin:0;">History Logs</h1>
                <input type="text" placeholder="Search snapshots..." oninput="filterLogs(this.value)" 
                      style="background:var(--card); border:1px solid var(--border); color:white; padding:10px 15px; border-radius:20px; outline:none; width:250px; font-size:13px;">
              </div>
              <div id="snapshotList">""" + snapshotsHtml + r"""</div>
            </div>

            <div id="fileInspector" style="display:none">
              <button onclick="closeInspector()" style="background:transparent; color:var(--accent); border:none; cursor:pointer; padding:0; margin-bottom:20px; font-size:14px; font-weight:bold; display:flex; align-items:center; gap:5px;">
                <span>&larr;</span> Back to Timeline
              </button>
              <h1 id="inspectTitle" style="margin:0 0 25px 0; font-size:22px;">Files in Snapshot</h1>
              <div id="fileList" style="display:grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap:15px;"></div>
            </div>
          </div>

          <div class="terminal-container">
            <div class="terminal-output" id="termOut">Welcome to Portable VCS Web Terminal. Type 'help' to begin.</div>
            <div class="terminal-input-area">
              <span class="prompt">vcs &gt;</span>
              <input type="text" class="cmd-input" id="cmdIn" placeholder="Enter command..." autofocus onkeydown="handleTermKey(event)">
              <span id="termLoader" class="loader"></span>
            </div>
          </div>
        </div>

        <div id="passwordModal">
          <div class="modal-content">
            <h3 id="modalTitle" style="margin-top:0;">🔒 Unlock Snapshot</h3>
            <p id="modalDesc" style="font-size:12px; color:var(--text-dim);">Enter your repository password to continue.</p>
            <input type="password" id="passInput" placeholder="Password...">
            <div style="display:flex; gap:12px;">
              <button onclick="submitPassword()" style="flex:2; padding:12px; background:var(--accent); color:white; border:none; border-radius:6px; cursor:pointer; font-weight:bold;">Confirm</button>
              <button onclick="closeModal()" style="flex:1; background:transparent; color:var(--text-dim); border:none; cursor:pointer; font-size:13px;">Cancel</button>
            </div>
          </div>
        </div>

        <div id="codeViewer">
          <div style="padding:15px 25px; border-bottom:1px solid var(--border); display:flex; justify-content:space-between; align-items:center; background:#161b22;">
            <div>
              <span style="color:var(--text-dim); font-size:12px;">FILE INSPECTOR</span>
              <div id="fileNameDisplay" style="font-weight:bold; font-family:monospace; color:var(--accent);"></div>
            </div>
            <button onclick="closeCode()" style="background:#30363d; color:white; border:none; padding:8px 20px; border-radius:6px; cursor:pointer; font-weight:600;">Close View</button>
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
          
          let cmdHistory = [];
          let historyIndex = -1;

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
            restoreDecision = confirm(`Switching to track "${trackName}".\n\nWould you like to restore the project files to the latest state of this track?`);
            if (restoreDecision) {
              document.getElementById('modalTitle').innerText = "🔑 Restore Encryption Key";
              document.getElementById('passwordModal').style.display = 'flex';
              document.getElementById('passInput').focus();
            } else {
              executeSwitch(trackName, '', false);
            }
          }

          async function executeSwitch(name, pass, restore) {
            const out = document.getElementById('termOut');
            toggleLoader(true);
            out.innerHTML += `<div style="color:var(--warning); margin-top:10px;">🔄 Switching track to: ${name}...</div>`;
            try {
              const resp = await fetch(`/api/switch-track?name=${encodeURIComponent(name)}&password=${encodeURIComponent(pass)}&restore=${restore}`);
              const data = await resp.json();
              if (data.success) {
                out.innerHTML += `<div style="color:var(--added)">✅ Track changed successfully. Refreshing UI...</div>`;
                setTimeout(() => location.reload(), 800);
              } else { 
                alert("Error: " + (data.error || "Failed to switch")); 
                toggleLoader(false);
              }
            } catch(e) { 
              alert("Network error"); 
              toggleLoader(false);
            }
          }

          function handleTermKey(e) {
            const input = document.getElementById('cmdIn');
            
            if(e.key === 'Enter') {
              const raw = input.value.trim();
              if(!raw) return;
              
              cmdHistory.push(raw);
              historyIndex = cmdHistory.length;
              
              const needsAuth = ['push', 'pull', 'status', 'diff'].some(cmd => raw.startsWith(cmd));
              if (needsAuth) {
                pendingCommand = raw;
                document.getElementById('modalTitle').innerText = "🔑 Authentication Required";
                document.getElementById('passwordModal').style.display = 'flex';
                document.getElementById('passInput').focus();
              } else { executeRaw(raw); }
            } 
            else if (e.key === 'ArrowUp') {
              if (historyIndex > 0) {
                historyIndex--;
                input.value = cmdHistory[historyIndex];
              }
              e.preventDefault();
            } 
            else if (e.key === 'ArrowDown') {
              if (historyIndex < cmdHistory.length - 1) {
                historyIndex++;
                input.value = cmdHistory[historyIndex];
              } else {
                historyIndex = cmdHistory.length;
                input.value = "";
              }
              e.preventDefault();
            }
          }

          function toggleLoader(show) {
            document.getElementById('termLoader').style.visibility = show ? 'visible' : 'hidden';
          }

          async function executeRaw(raw, pass = '') {
            if(!raw.trim()) return;
            const out = document.getElementById('termOut');
            document.getElementById('cmdIn').value = '';
            toggleLoader(true);
            
            out.innerHTML += `<div style="color:var(--accent); margin-top:10px; font-weight:bold;">$ vcs ${raw}</div>`;
            try {
              const resp = await fetch(`/api/command?raw=${encodeURIComponent(raw)}&password=${encodeURIComponent(pass)}`);
              const data = await resp.json();
              
              out.innerHTML += `<div style="margin-bottom:10px;">${data.output}</div>`;
              out.scrollTop = out.scrollHeight;
              
              if(data.refresh) {
                out.innerHTML += `<div style="color:var(--warning)">♻️ Action requires UI refresh...</div>`;
                setTimeout(() => location.reload(), 1200);
              }
            } catch(e) { 
              out.innerHTML += `<div style="color:var(--error)">❌ Connection to local server lost.</div>`; 
            } finally {
              toggleLoader(false);
            }
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
            pendingCommand = null;
            pendingTrackName = null;
          }

          window.addEventListener('keydown', (e) => {
            if(e.key === 'Escape') {
              closeModal();
              closeCode();
            }
          });

          function closeInspector() { 
            document.getElementById('fileInspector').style.display = 'none';
            document.getElementById('viewList').style.display = 'block';
          }

          async function submitPassword() {
            const pass = document.getElementById('passInput').value;
            if(!pass) return;

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
                } else { 
                  alert("Incorrect password for this repository."); 
                  document.getElementById('passInput').value = '';
                }
              } catch(e) { alert("Error connecting to server"); }
            }
          }

          function renderFiles(files) {
            document.getElementById('viewList').style.display = 'none';
            document.getElementById('fileInspector').style.display = 'block';
            
            if(files.length === 0) {
              document.getElementById('fileList').innerHTML = '<div style="color:var(--text-dim)">No files in this snapshot.</div>';
              return;
            }

            document.getElementById('fileList').innerHTML = files.map(f => `
              <div class="snapshot-card" onclick="viewCode('${f.name}')">
                <span style="display:flex; align-items:center; gap:10px;">
                  <span style="font-size:18px;">${getFileIcon(f.name)}</span> 
                  ${f.name}
                </span>
                <span class="badge-status ${f.status}">${f.status}</span>
              </div>
            `).join('');
          }

          function getFileIcon(name) {
            if(name.endsWith('.dart')) return '🎯';
            if(name.endsWith('.js') || name.endsWith('.ts')) return '📜';
            if(name.endsWith('.json')) return '⚙️';
            if(name.endsWith('.md')) return '📝';
            if(name.endsWith('.yaml')) return '🛠️';
            return '📄';
          }

          async function viewCode(file) {
            const left = document.getElementById('leftPane');
            const right = document.getElementById('rightPane');
            
            left.innerHTML = '<div style="padding:20px; color:var(--text-dim)">Loading diff...</div>';
            right.innerHTML = '';
            
            document.getElementById('fileNameDisplay').innerText = file;
            document.getElementById('codeViewer').style.display = 'flex';

            try {
              const resp = await fetch(`/api/content?id=${currentId}&password=${encodeURIComponent(currentPass)}&file=${encodeURIComponent(file)}`);
              const data = await resp.json();
              
              left.innerHTML = data.left || '<div class="diff-line empty" style="padding:15px; text-align:center;">(File did not exist)</div>';
              right.innerHTML = data.right;

              left.onscroll = () => { right.scrollTop = left.scrollTop; right.scrollLeft = left.scrollLeft; };
              right.onscroll = () => { left.scrollTop = right.scrollTop; left.scrollLeft = right.scrollLeft; };

            } catch(e) { 
              left.innerHTML = '<div style="padding:20px; color:var(--error)">Error loading file content.</div>';
            }
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

  Future<void> checkStorageHealth() async {
    final context = await loadRepoContext();
    if (context == null) return;

    final driveRoot = p.split(context.remoteRepoDir.path).first;
    final driveLetterOnly = driveRoot.replaceAll(RegExp(r'[^A-Za-z]'), '');
    final drivePath = context.remoteRepoDir.parent.path;

    print('\n💾 ${" SYSTEM STORAGE DIAGNOSTIC ".black.onCyan}');
    print('${"Target Mount:".yellow} ${driveRoot.bold} (${drivePath.grey})');
    print('═' * 60);

    try {
      if (Platform.isWindows) {
        final psHealth = 'Get-Partition -DriveLetter $driveLetterOnly | Get-Disk | Select-Object HealthStatus | ConvertTo-Json';
        final healthRes = await Process.run('powershell', ['-Command', psHealth], runInShell: true);
        
        print('🩺 ${"Hardware Integrity:".bold}');
        if (healthRes.stdout.toString().contains('Healthy')) {
          print('   Status: ${"HEALTHY".green} | Device: ${"Verified".blue}');
        } else {
          print('   Status: ${"UNKNOWN/CAUTION".yellow}');
        }
      }

      print('\n⚡ ${"IO Performance Test:".bold}');
      final testFile = File(p.join(drivePath, '.vcs_health_test'));
      final watch = Stopwatch()..start();
      
      await testFile.writeAsBytes(List.generate(1024 * 1024, (i) => i % 255));
      final writeTime = watch.elapsedMilliseconds;
      
      watch.reset();
      watch.start();
      await testFile.readAsBytes();
      final readTime = watch.elapsedMilliseconds;
      watch.stop();

      if (await testFile.exists()) await testFile.delete();

      if (Platform.isWindows) {
        final psUsage = 'Get-PSDrive $driveLetterOnly | Select-Object Used, Free | ConvertTo-Json';
        final usageRes = await Process.run('powershell', ['-Command', psUsage], runInShell: true);
        
        if (usageRes.exitCode == 0) {
          final data = jsonDecode(usageRes.stdout.toString());
          final double used = (data['Used'] ?? 0).toDouble();
          final double free = (data['Free'] ?? 0).toDouble();
          final double total = used + free;

          if (total > 0) {
            final percent = (used / total * 100).clamp(0, 100).toInt();
            
            final barLength = 30;
            int filled = (percent * barLength / 100).toInt();
            if (percent > 0 && filled == 0) filled = 1; 

            final barChars = '█' * filled + '░' * (barLength - filled);
            final coloredBar = percent > 90 ? barChars.red : (percent > 70 ? barChars.yellow : barChars.green);

            print('\n📊 ${"Storage Usage:".bold}');
            print('   [$coloredBar] $percent%');
            print('   Used: ${_formatBytes(used.toInt()).grey} / Total: ${_formatBytes(total.toInt()).grey}');
          }
        }
      }

      final wStatus = writeTime < 150 ? "OPTIMAL".green : (writeTime < 500 ? "ACCEPTABLE".yellow : "SLOW".red);
      final rStatus = readTime < 50 ? "OPTIMAL".green : (readTime < 200 ? "ACCEPTABLE".yellow : "SLOW".red);

      print('\n⏱️  ${"Latency Analysis:".bold}');
      print('   ${"Write (1MB):".padRight(18)} ${"$writeTime ms".bold.padRight(10)} [$wStatus]');
      print('   ${"Read (1MB):".padRight(18)} ${"$readTime ms".bold.padRight(10)} [$rStatus]');

    } catch (e) {
      print('\n❌ ${"Diagnostic Error:".red} ${e.toString().grey}');
    }
    
    print('\n' + '═' * 60 + '\n');
  }

  Future<void> runBenchmark({bool intensive = false}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final String drivePath = context.remoteRepoDir.path;
    
    print('\n🏎️  ${" VCS PERFORMANCE BENCHMARK ".black.onCyan}');
    print('${"OS:".grey} ${Platform.operatingSystem.toUpperCase()} | ${"Target:".grey} ${drivePath.bold}');
    print('═' * 60);

    await _showDiskUsage(drivePath);

    final testDir = Directory(p.join(drivePath, '.vcs_bench'));
    if (!testDir.existsSync()) await testDir.create();

    try {
      print('\n📂 ${"Task 1: IOPS Test (100 small files)...".bold}');
      final iopsWatch = Stopwatch()..start();
      for (int i = 0; i < 100; i++) {
        final f = File(p.join(testDir.path, 'iops_$i.tmp'));
        await f.writeAsBytes([i], flush: true);
      }
      iopsWatch.stop();
      final iopsResult = iopsWatch.elapsedMilliseconds;
      print('   Result: ${iopsResult}ms ${iopsResult < 1000 ? "⚡" : "🐢"}');

      print('\n🔐 ${"Task 2: Encryption Engine (PBKDF2 + AES-GCM)...".bold}');
      print('   ${"Processing: 1MB mock payload with 120k iterations".grey}');
      final dummyZip = Uint8List.fromList(List.generate(1024 * 1024, (i) => i % 256));
      
      final cryptoWatch = Stopwatch()..start();
      await _encryptSnapshot(
        zipBytes: dummyZip,
        message: "Benchmark test",
        password: "password-de-prueba-muy-larga-123",
        author: "VCS-Benchmark"
      );
      cryptoWatch.stop();
      final cryptoResult = cryptoWatch.elapsedMilliseconds;
      print('   Result: ${cryptoResult}ms');

      final int sizeMB = intensive ? 50 : 10;
      print('\n📦 ${"Task 3: Sequential Write ($sizeMB MB)...".bold}');
      final bigData = Uint8List.fromList(List.generate(1024 * 1024 * sizeMB, (i) => i % 256));
      
      final seqWatch = Stopwatch()..start();
      final bigFile = File(p.join(testDir.path, 'large.tmp'));
      await bigFile.writeAsBytes(bigData, flush: true);
      seqWatch.stop();
      
      final double mbps = (sizeMB / (seqWatch.elapsedMilliseconds / 1000));
      print('   Result: ${seqWatch.elapsedMilliseconds}ms (${mbps.toStringAsFixed(2)} MB/s)');

      print('\n' + '═' * 60);
      _displayFinalScore(iopsResult, cryptoResult, mbps);

    } catch (e) {
      print('\n❌ ${"Benchmark interrupted:".red} $e');
    } finally {
      if (testDir.existsSync()) await testDir.delete(recursive: true);
    }
  }

  Future<void> _showDiskUsage(String path) async {
    if (Platform.isWindows) {
    } else if (Platform.isLinux || Platform.isMacOS) {
      try {
        final res = await Process.run('df', ['-h', path]);
        final lines = res.stdout.toString().split('\n');
        if (lines.length > 1) {
          print('📊 ${"Disk Usage (Unix):".bold}\n   ${lines[1].grey}');
        }
      } catch (_) {
        print('📊 ${"Disk Usage:".bold} (Information unavailable)');
      }
    }
  }

  void _displayFinalScore(int iops, int crypto, double mbps) {
    String grade;
    String advice;

    if (iops < 800 && mbps > 25) {
      grade = "GOLD 🏆";
      advice = "Perfect for large projects and heavy histories.";
    } else if (iops < 1500 && mbps > 10) {
      grade = "SILVER 🥈";
      advice = "Good performance for daily development.";
    } else {
      grade = "BRONZE 🥉";
      advice = "Slow I/O. Expect delays during push/pull.";
    }

    print(' ${"FINAL RATING:".bold} $grade');
    print(' ${"Encryption Latency:".grey} ${crypto}ms (Impact of PBKDF2)');
    print(' ${"Recommendation:".grey} $advice');
    print('═' * 60 + '\n');
  }

  Future<void> info({bool showCharts = false}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final meta = context.remoteMeta;
    final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
    final metaFile = File(p.join(context.remoteRepoDir.path, remoteMetaFileName));
    final backupFile = File('${metaFile.path}.bak');

    print('\nℹ️  ${" PROJECT ARCHIVE DASHBOARD ".black.onCyan}');
    print('${"Project Name:".yellow.padRight(22)} ${meta.projectName.bold}');
    print('${"Active Track:".yellow.padRight(22)} ${meta.activeTrack.magenta.bold}');
    print('${"Vault ID:".yellow.padRight(22)} ${meta.repoId.grey}');
    print('─' * 60);

    int totalSnapshots = 0;
    String largestTrackName = 'none';
    int maxSnapshots = 0;
    
    for (var entry in meta.tracks.entries) {
      final count = entry.value.logs.length;
      totalSnapshots += count;
      if (count > maxSnapshots) {
        maxSnapshots = count;
        largestTrackName = entry.key;
      }
    }

    double totalSizeMb = 0;
    int fileCount = 0;
    if (await snapshotsDir.exists()) {
      final files = snapshotsDir.listSync().whereType<File>();
      fileCount = files.length;
      final totalBytes = files.fold<int>(0, (sum, file) => sum + file.lengthSync());
      totalSizeMb = totalBytes / (1024 * 1024);
    }

    if (showCharts) {
      print('📅 ${"Activity Timeline (Last 7 Days):".bold}');
      final now = DateTime.now();
      final Map<String, int> dailyCounts = {};

      for (int i = 6; i >= 0; i--) {
        final date = now.subtract(Duration(days: i));
        final dateStr = "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
        dailyCounts[dateStr] = 0;
      }

      for (final track in meta.tracks.values) {
        for (final entry in track.logs) {
          try {
            final date = DateTime.parse(entry.createdAt);
            final dateStr = "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
            if (dailyCounts.containsKey(dateStr)) {
              dailyCounts[dateStr] = dailyCounts[dateStr]! + 1;
            }
          } catch (_) {}
        }
      }

      final maxDayCount = dailyCounts.values.fold(0, (a, b) => a > b ? a : b);
      dailyCounts.forEach((date, count) {
        final barWidth = maxDayCount == 0 ? 0 : (count / maxDayCount * 25).round();
        final bar = '█' * barWidth;
        final label = count > 0 ? count.toString().padLeft(2).green : '0'.grey;
        print('   $date | ${count > 0 ? bar.green : '░'.grey} $label');
      });
      print('                └' + '─' * 26 + '\n');
    }

    print('📈 ${"Metrics & Health:".bold}');
    final avgSize = totalSnapshots > 0 ? totalSizeMb / totalSnapshots : 0;
    final healthStatus = (await backupFile.exists()) ? "SECURE".green : "UNPROTECTED".red;

    print('   ${"Status:".padRight(20)} $healthStatus');
    print('   ${"Total Snapshots:".padRight(20)} ${totalSnapshots.toString().cyan} ($fileCount files on disk)');
    print('   ${"Storage Used:".padRight(20)} ${totalSizeMb.toStringAsFixed(2).yellow} MB');
    print('   ${"Avg Snapshot:".padRight(20)} ${avgSize.toStringAsFixed(2).grey} MB');

    if (meta.tags.isNotEmpty) {
      print('\n🏷️  ${"Latest Milestones:".bold}');
      final sortedTags = meta.tags.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
      final displayTags = sortedTags.take(3);
      for (var tag in displayTags) {
        print('   ${tag.key.magenta.padRight(20)} ${"→".grey} ${tag.value.substring(0, 8).green}...');
      }
    }

    print('\n🔒 ${"Infrastructure:".bold}');
    print('   ${"Format:".padRight(20)} VCS Standard v${meta.formatVersion}');
    print('   ${"Encryption:".padRight(20)} AES-256-GCM (Hardware Accelerated)');
    print('   ${"Mirroring:".padRight(20)} ${backupFile.path.split(p.separator).last.grey}');

    String remoteUrl = 'Not linked';
    try {
      final gitResult = await Process.run('git', ['remote', 'get-url', 'origin']);
      if (gitResult.exitCode == 0) remoteUrl = gitResult.stdout.toString().trim();
    } catch (_) {}
    print('   ${"Git Remote:".padRight(20)} ${remoteUrl.blue}');

    print('\n' + '─' * 60);
    print('${"Last synchronization:".grey} ${meta.updatedAt}');
    print('');
  }

  Future<void> gitStash({bool pop = false, bool list = false, bool clear = false, String? drop}) async {
    print('\n📦 ${"GIT STASH MANAGER".black.onCyan}');
    
    try {
      if (list) {
        final result = await Process.run('git', ['stash', 'list'], runInShell: true);
        print('${"Current Saved States:".bold}');
        final output = result.stdout.toString().trim();
        print(output.isEmpty ? "    (No stashed changes found)".grey : output);
        return;
      }

      if (clear) {
        print('⚠️  ${"Deleting all saved stashes...".red}');
        await Process.run('git', ['stash', 'clear'], runInShell: true);
        print('✅ ${"Stash history cleared.".green}');
        return;
      }

      if (drop != null) {
        print('🗑️  ${"Dropping $drop...".yellow}');
        final result = await Process.run('git', ['stash', 'drop', drop], runInShell: true);
        if (result.exitCode == 0) {
          print('✅ ${"Dropped successfully.".green}');
        } else {
          print('❌ ${"Error:".red} ${result.stderr}');
        }
        return;
      }

      if (pop) {
        print('⏳ ${"Restoring and removing last saved changes...".yellow}');
        final result = await Process.run('git', ['stash', 'pop'], runInShell: true);
        
        if (result.exitCode == 0) {
          print('✅ ${"Changes restored and removed from stash.".green}');
        } else {
          print('❌ ${"Conflict detected or Pop failed:".red}');
          print('${result.stderr.toString().grey}');
          print('\n💡 ${"Tip: Resolve conflicts manually or check 'git status'".grey}');
        }
        return;
      }

      print('⏳ ${"Saving current Git working tree (including new files)...".yellow}');
      final timestamp = DateTime.now().toString().split('.')[0];

      final result = await Process.run(
        'git', 
        ['stash', 'push', '--include-untracked', '-m', 'VCS Auto-stash at $timestamp'], 
        runInShell: true
      );

      final out = result.stdout.toString();
      if (out.contains('No local changes to save')) {
        print('✨ ${"Nothing to save, tree is already clean.".green}');
      } else {
        print('✅ ${"Working tree DEEP CLEANED and saved.".green}');
        print('   ${"New files (untracked) were also stashed.".grey}');
      }

    } catch (e) {
      print('❌ ${"Git Error:".red} $e');
    }
    print('─' * 60 + '\n');
  }

  Future<void> migrateVault({required String targetPath, bool deleteSource = false}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final sourceDir = context.remoteRepoDir;
    final folderName = p.basename(sourceDir.parent.path);
    final destinationDir = Directory(p.join(targetPath, '.vcs_portable', folderName));

    print('\n🚚 ${"VAULT MIGRATION".black.onCyan}');
    print('${"From:".yellow} ${sourceDir.path.grey}');
    print('${"To:  ".yellow} ${destinationDir.path.green}');
    print('─' * 60);

    try {
      if (destinationDir.existsSync()) {
        print('❌ ${"Target directory already exists. Migration aborted to prevent overwrite.".red}');
        return;
      }

      print('⏳ ${"Step 1/3: Preparing destination..."}');
      destinationDir.createSync(recursive: true);

      print('⏳ ${"Step 2/3: Copying encrypted snapshots and metadata..."}');
      await _copyDirectory(sourceDir, destinationDir);

      print('⏳ ${"Step 3/3: Verifying migration..."}');
      final sourceCount = sourceDir.listSync(recursive: true).length;
      final destCount = destinationDir.listSync(recursive: true).length;

      if (sourceCount == destCount) {
        print('\n✅ ${"Migration successful!".green}');
        print('📊 ${"Total objects migrated:".grey} $destCount');
        
        if (deleteSource) {
          print('\n🗑️  ${"Deleting source data as requested..."}');
          await sourceDir.delete(recursive: true);
          print('✅ ${"Source wiped.".green}');
        }

        print('\n💡 ${"Next step:".cyan} Remember to use ${"vcs bind".yellow} if you change your drive letter.');
      } else {
        throw Exception("File count mismatch. Source: $sourceCount, Dest: $destCount");
      }

    } catch (e) {
      print('\n❌ ${"Migration failed:".red} $e');
      if (destinationDir.existsSync()) {
        print('🧹 ${"Cleaning up partial migration...".grey}');
        await destinationDir.delete(recursive: true);
      }
    }
    print('─' * 60 + '\n');
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (var entity in source.list(recursive: false)) {
      if (entity is Directory) {
        final newDirectory = Directory(p.join(destination.absolute.path, p.basename(entity.path)));
        await newDirectory.create();
        await _copyDirectory(entity, newDirectory);
      } else if (entity is File) {
        await entity.copy(p.join(destination.path, p.basename(entity.path)));
      }
    }
  }

  Future<void> checkUpdatesSilently() async {
    final cacheFile = File(p.join(Directory.systemTemp.path, '.vcs_update_cache'));
    String? cachedLatest;
    DateTime? lastCheck;

    bool isUpdateAvailable(String local, String remote) {
      try {
        if (local == remote) return false;
        List<int> parse(String v) {
          final clean = v.replaceAll('-Experimental.', '.').replaceAll('-', '.');
          return clean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
        }
        final localParts = parse(local);
        final remoteParts = parse(remote);
        final maxLen = localParts.length > remoteParts.length ? localParts.length : remoteParts.length;
        for (var i = 0; i < maxLen; i++) {
          final l = i < localParts.length ? localParts[i] : 0;
          final r = i < remoteParts.length ? remoteParts[i] : 0;
          if (r > l) return true;
          if (l > r) return false;
        }
      } catch (_) { return false; }
      return false;
    }

    if (cacheFile.existsSync()) {
      try {
        final lines = await cacheFile.readAsLines();
        if (lines.length >= 2) {
          cachedLatest = lines[0];
          lastCheck = DateTime.parse(lines[1]);
        }
      } catch (_) {}
    }

    if (cachedLatest != null && isUpdateAvailable(vcsBaseVersion, cachedLatest)) {
      _printUpdateToast(vcsBaseVersion, cachedLatest);
    }

    final bool isFirstTime = lastCheck == null;
    final bool isExpired = !isFirstTime && DateTime.now().difference(lastCheck).inHours >= 24;

    if (isFirstTime) {
      try {
        final latestV = await _getLatestGitHubVersion().timeout(const Duration(seconds: 2));
        if (latestV != null) {
          await cacheFile.writeAsString('$latestV\n${DateTime.now().toIso8601String()}');
          if (isUpdateAvailable(vcsBaseVersion, latestV) && latestV != cachedLatest) {
            _printUpdateToast(vcsBaseVersion, latestV);
          }
        }
      } catch (_) { /* Silent */ }
    } 
    else if (isExpired) {
      _getLatestGitHubVersion().then((latestV) async {
        if (latestV != null) {
          final data = '$latestV\n${DateTime.now().toIso8601String()}';
          await cacheFile.writeAsString(data);
        }
      }).catchError((_) {});
    }
  }

  Future<void> tag(String tagName, {String? snapshotId, String? track}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrack = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrack];

    if (trackData == null || trackData.logs.isEmpty) {
      print('❌ No snapshots found in track "$targetTrack" to tag.');
      return;
    }

    final idToTag = snapshotId ?? trackData.logs.first.id;
    final exists = trackData.logs.any((e) => e.id == idToTag);
    if (!exists) {
      print('❌ Snapshot ID "$idToTag" not found in track "$targetTrack".');
      return;
    }
    final updatedTags = Map<String, String>.from(context.remoteMeta.tags);
    
    if (updatedTags.containsKey(tagName)) {
      print('ℹ️  Moving tag ${tagName.cyan} from ${updatedTags[tagName]!.grey} to ${idToTag.green}');
    }

    updatedTags[tagName] = idToTag;

    final updatedMeta = context.remoteMeta.copyWith(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      tags: updatedTags,
    );

    final metaFile = File(p.join(context.remoteRepoDir.path, remoteMetaFileName));
    await _atomicWriteString(
      metaFile,
      const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
    );

    print('✅ Tag ${tagName.magenta.bold} successfully linked to ${idToTag.green}');
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
  String get onBlue => '\x1B[44m$this\x1B[0m';
  String get onMagenta => '\x1B[45m$this\x1B[0m';
  String get onWhite => '\x1B[47m$this\x1B[0m';
  String get onBlack => '\x1B[40m$this\x1B[0m';
  String get black => '\x1B[30m$this\x1B[0m';
}

Future<void> main(List<String> args) async {
  final app = PortableVcs();
  try {
    await runWithArgs(args, app);
  } finally {
    final cmd = args.isNotEmpty ? args[0].toLowerCase() : '';
    if (cmd != 'update' && cmd != 'version') {
      await app.checkUpdatesSilently();
    }
  }
}

Future<void> runWithArgs(List<String> args, PortableVcs app, {String? password}) async {
  app.currentWebPassword = password;

  final parser = ArgParser()
    ..addCommand('setup')
    ..addCommand('init')
    ..addCommand('status')
    ..addCommand('update')
    ..addCommand('changelog')
    ..addCommand('storage-check', ArgParser()
      ..addFlag('full', negatable: false, help: 'Perform a more intensive read check')
    )
    ..addCommand('note', ArgParser()
      ..addOption('id', help: 'Target snapshot ID')
      ..addOption('author', abbr: 'a')
      ..addFlag('remove', abbr: 'r', negatable: false, help: 'Remove a note')
      ..addOption('index', abbr: 'i', help: 'Index of the note to remove')
      ..addFlag('all', negatable: false, help: 'Remove all notes from the snapshot')
    )
    ..addCommand('tag', ArgParser()
      ..addOption('id', abbr: 'i', help: 'Specific snapshot ID to tag')
      ..addOption('track', abbr: 't', help: 'Track where the snapshot resides')
    )
    ..addCommand('alias', ArgParser()
      ..addOption('set', abbr: 's', help: 'Set a new alias. Usage: vcs alias --set "xp=pull -t Experimentos"')
      ..addOption('rm', help: 'Remove an alias')
      ..addFlag('list', abbr: 'l', negatable: false, help: 'List all aliases')
    )
    ..addCommand('migrate', ArgParser()
      ..addOption('to', abbr: 'd', help: 'Path to the new device or network folder')
      ..addFlag('delete-source', negatable: false, help: 'Remove data from the old drive after migration'),
    )
    ..addCommand('log', ArgParser()
      ..addFlag('full', negatable: false)
      ..addFlag('summary', negatable: false)
      ..addFlag('standard', negatable: false)
      ..addFlag('graph', abbr: 'g', negatable: false, help: 'Visual representation of the snapshot history.')
      ..addOption('track', abbr: 't', help: 'Show logs from a specific track instead of the active one'),
    )
    ..addCommand('show', ArgParser()
      ..addOption('track', abbr: 't', help: 'Target track to look for the snapshot')
    )
    ..addCommand('pull', ArgParser()
      ..addOption('track', abbr: 't', help: 'Pull from a specific track')
      ..addOption('id', help: 'Pull a specific snapshot ID')
      ..addFlag('dry-run', negatable: false, help: 'Preview changes without modifying files'),
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
    ..addCommand('verify', ArgParser()
      ..addFlag('all', negatable: false, help: 'Verify all snapshots in repository'),
    )
    ..addCommand('bind')
    ..addCommand('diff', ArgParser())
    ..addCommand('info', ArgParser()
      ..addFlag('charts', negatable: false, help: 'Show activity histogram for the last 7 days')
    )
    ..addCommand('tree', ArgParser()
      ..addOption('track', abbr: 't', help: 'Target track to visualize')
    )
    ..addCommand('push', ArgParser()
        ..addOption('author', abbr: 'a')
        ..addOption('track', abbr: 't', help: 'Push to a specific track instead of the active one')
        ..addFlag('amend', negatable: false, help: 'Overwrite the last snapshot in the track')
    )
    ..addCommand('revert')
    ..addCommand('restore', ArgParser()..addOption('to'))
    ..addCommand('clone', ArgParser()..addOption('into'))
    ..addCommand('prune', ArgParser()
      ..addOption('id', abbr: 'i', help: 'Delete a specific snapshot by its ID.')
      ..addOption('keep', abbr: 'k', help: 'Keep only the newest N snapshots.')
      ..addOption('older-than', abbr: 'd', help: 'Delete snapshots older than N days.')
      ..addFlag('garbage', abbr: 'g', negatable: false, help: 'Remove orphan and temp files.'),
    )
    ..addCommand('git-prepare', ArgParser()
      ..addOption('branch', defaultsTo: 'main')
      ..addFlag('dry-run', negatable: false),
    )
    ..addCommand('git-diff', ArgParser()
      ..addOption('branch', defaultsTo: 'main'),
    )
    ..addCommand('track', ArgParser()
      ..addCommand('list')
      ..addCommand('current')
      ..addCommand('create')
      ..addCommand('switch')
      ..addCommand('delete'),
    )
    ..addCommand('version')
    ..addCommand('ui')
    ..addCommand('stash', ArgParser()
      ..addFlag('pop', abbr: 'p', negatable: false, help: 'Restore and remove the last stash')
      ..addFlag('list', abbr: 'l', negatable: false, help: 'List all saved stashes')
      ..addFlag('clear', negatable: false, help: '⚠️ Delete ALL stashed changes permanently')
      ..addOption('drop', help: 'Delete a specific stash (e.g., stash@{0})')
    )
    ..addCommand('search', ArgParser()
      ..addOption('track', abbr: 't', help: 'Search in a specific track')
      ..addOption('id', help: 'Search only in a specific snapshot ID')
      ..addOption('max', abbr: 'm', help: 'Search only in the last N snapshots')
      ..addFlag('case-sensitive', abbr: 's', negatable: false, help: 'Perform a case-sensitive search')
    )
    ..addCommand('timeline', ArgParser()
      ..addOption('track', abbr: 't', help: 'Track to visualize')
      ..addOption('limit', abbr: 'n', help: 'Number of snapshots to show', defaultsTo: '15')
    )
    ..addCommand('benchmark', ArgParser()
      ..addFlag('intensive', abbr: 'i', negatable: false, help: 'Run a longer stress test')
    )
    ..addCommand('publish', ArgParser()
      ..addOption('branch', defaultsTo: 'main', abbr: 'b')
      ..addOption('remote', defaultsTo: 'origin', abbr: 'r')
      ..addFlag('dry-run', negatable: false)
      ..addFlag('verify', defaultsTo: true, help: 'Run security hooks before publishing'),
    );

  if (args.isEmpty) {
    app.showHelp();
    return;
  }

  final context = await app.loadRepoContext();
  Map<String, String> aliases = {};
  AliasManager? aliasMgr;

  if (context != null) {
    aliasMgr = AliasManager(context.remoteRepoDir);
    aliases = await aliasMgr.loadAliases();
    
    final String firstArg = args.first;
    if (aliases.containsKey(firstArg) && firstArg != 'alias') {
      final String expanded = aliases[firstArg]!;
      print('🚀 ${"Alias detected:".grey} ${firstArg.cyan} -> ${expanded.yellow}');
      args = [...expanded.split(' '), ...args.skip(1)];
    }
  }

  try {
    final result = parser.parse(args);
    final command = result.command;
    final commandName = command?.name;

    switch (commandName) {
      case 'alias':
        if (aliasMgr == null) {
          print('❌ ${"Error:".red} USB storage context not found. Cannot manage aliases.');
          return;
        }
        if (command!['list'] == true) {
          if (aliases.isEmpty) {
            print('\n  ${"No aliases configured.".grey}');
          } else {
            print('\n📌 ${"CURRENT ALIASES (USB):".bold.cyan}');
            aliases.forEach((k, v) => print('  ${k.green.padRight(12)} -> ${v.yellow}'));
          }
        } else if (command['set'] != null) {
          final input = command['set'].toString();
          if (!input.contains('=')) {
            print('❌ Invalid format. Use: vcs alias --set "name=command"');
          } else {
            final parts = input.split('=');
            await aliasMgr.saveAlias(parts[0].trim(), parts[1].trim());
            print('✅ Alias ${parts[0].trim().green} saved successfully.');
          }
        } else if (command['rm'] != null) {
          await aliasMgr.removeAlias(command['rm'].toString());
          print('🗑️ Alias removed.');
        }
        break;

      case 'setup': await app.setupDrive(); break;
      case 'init': await app.init(); break;
      case 'status': await app.status(); break;
      case 'update': await app.update(); break;
      case 'changelog': app.showChangelog(); break;
      case 'version': app.showVersion(); break;
      case 'ui': await app.launchUI(); break;
      case 'list': await app.listRepos(); break;
      case 'doctor': await app.doctor(); break;
      case 'stats': await app.stats(); break;
      case 'clear-history': await app.clearHistory(); break;
      case 'purge': await app.purge(); break;
      case 'storage-check': await app.checkStorageHealth(); break;
      case 'benchmark': await app.runBenchmark(); break;


      case 'note':
        final bool isRemove = command!['remove'] as bool;
        final bool removeAll = command['all'] as bool;
        final String? snapshotId = command['id']?.toString();

        if (isRemove || removeAll) {
          final int? index = command['index'] != null ? int.tryParse(command['index']) : null;
          await app.removeNote(
            snapshotId: snapshotId,
            index: index,
            all: removeAll,
          );
        } else {
          if (command.rest.isEmpty) {
            print('❌ You must provide the note text.');
          } else {
            await app.addNote(
              command.rest.join(' '),
              snapshotId: snapshotId,
              author: command['author']?.toString(),
            );
          }
        }
        break;

      case 'tag':
        final tagName = command?.rest.firstOrNull;

        if (tagName == null) {
          print('❌ Usage: vcs tag <tag_name> [--id <id>] [--track <name>]');
        } else {
          if (!RegExp(r'^[a-zA-Z0-9\._\-]+$').hasMatch(tagName)) {
            print('❌ Invalid tag name. Use only letters, numbers, dots, dashes or underscores.');
          } else {
            await app.tag(
              tagName,
              snapshotId: command?['id']?.toString(),
              track: command?['track']?.toString(),
            );
          }
        }
        break;

      case 'timeline':
        await app.timeline(
          track: command?['track']?.toString(),
          limit: int.tryParse(command?['limit']?.toString() ?? '15') ?? 15,
        );
        break;

      case 'info':
        await app.info(showCharts: command!['charts'] == true);
        break;

      case 'bind':
        final repoId = command!.rest.isNotEmpty ? command.rest.first : null;
        await app.bindRepo(repoId: repoId);
        break;

      case 'diff':
        await app.diff(command?.rest ?? []);
        break;

      case 'log':
        LogViewMode mode = LogViewMode.summary;
        if (command!['full'] == true) mode = LogViewMode.full;
        else if (command['standard'] == true) mode = LogViewMode.standard;
        await app.log(
          mode: mode, 
          track: command['track']?.toString(),
          showGraph: command['graph'] == true
        );
        break;

      case 'show':
        await app.showSnapshot(
          command!.rest.isNotEmpty ? command.rest.first : null, 
          track: command['track'] as String?
        );
        break;

      case 'pull':
        await app.pull(
          track: command!['track']?.toString(),
          snapshotId: command['id']?.toString(),
          dryRun: command['dry-run'] == true,
        );
        break;

      case 'summary':
        await app.showCommitHelper(track: command!['track']?.toString());
        break;

      case 'verify':
        await app.verify(
          snapshotId: command!.rest.isNotEmpty ? command.rest.first : null,
          verifyAll: command['all'] == true,
        );
        break;

      case 'revert':
        if (command!.rest.isEmpty) {
          print('❌ You must provide a snapshot ID.');
        } else {
          await app.revert(command.rest.first);
        }
        break;

      case 'restore':
        if (command!.rest.isEmpty) {
          print('❌ You must provide a snapshot ID.');
        } else {
          final to = command['to']?.toString();
          if (to == null || to.isEmpty) {
            print('❌ You must provide a destination with --to <path>.');
          } else {
            await app.restoreTo(command.rest.first, to);
          }
        }
        break;

      case 'push':
        if (command!.rest.isEmpty) {
          print('❌ You must provide a message.');
        } else {
          await app.push(
            command.rest.join(' '),
            author: command['author']?.toString(),
            track: command['track']?.toString(),
            amend: command['amend'] as bool,
          );
        }
        break;

      case 'clone':
        await app.cloneRepo(
          repoId: command!.rest.isNotEmpty ? command.rest.first : null, 
          into: command['into']?.toString()
        );
        break;

      case 'prune':
        await app.prune(
          snapshotId: command!['id']?.toString(),
          keep: int.tryParse(command['keep']?.toString() ?? ''),
          olderThanDays: int.tryParse(command['older-than']?.toString() ?? ''),
          garbage: command['garbage'] == true
        );
        break;

      case 'git-prepare':
        await app.gitPrepare(
          snapshotId: command!.rest.isNotEmpty ? command.rest.first : null,
          branch: command['branch'].toString(),
          dryRun: command['dry-run'] == true,
        );
        break;

      case 'publish':
        await app.publish(
          snapshotId: command!.rest.isNotEmpty ? command.rest.first : null,
          branch: command['branch'].toString(),
          remote: command['remote'].toString(),
          dryRun: command['dry-run'] == true,
          verify: command['verify'] == true,
        );
        break;

      case 'tree':
        await app.tree(
          command!.rest.isNotEmpty ? command.rest.first : null, 
          command['track'] as String?
        );
        break;

      case 'git-diff':
        await app.gitDiff(
          snapshotId: command!.rest.isNotEmpty ? command.rest.first : null,
          branch: command['branch'].toString(),
        );
        break;

      case 'track':
        final sub = command!.command;
        if (sub == null) {
          print('❌ ${"Usage: vcs track <list|current|create|switch|delete> [name]".red}');
        } else {
          switch (sub.name) {
            case 'list': await app.trackList(); break;
            case 'current': await app.trackCurrent(); break;
            case 'create': 
              if (sub.rest.isEmpty) print('❌ Track name required.');
              else await app.trackCreate(sub.rest.first); 
              break;
            case 'switch': 
              if (sub.rest.isEmpty) print('❌ Track name required.');
              else await app.trackSwitch(sub.rest.first); 
              break;
            case 'delete': 
              if (sub.rest.isEmpty) print('❌ Track name required.');
              else await app.trackDelete(sub.rest.first); 
              break;
          }
        }
        break;

      case 'stash':
        await app.gitStash(
          pop: command!['pop'] == true,
          list: command['list'] == true,
          clear: command['clear'] == true,
          drop: command['drop']?.toString(),
        );
        break;

      case 'migrate':
        final to = command!['to']?.toString();
        if (to == null) {
          print('❌ Target path required: --to <path>');
        } else {
          await app.migrateVault(targetPath: to, deleteSource: command['delete-source'] == true);
        }
        break;

      case 'search':
        if (command!.rest.isEmpty) {
          print('\n❌ Usage: vcs search <query> [options]');
          return;
        }
        await app.search(
          command.rest.join(' '),
          track: command['track'],
          caseSensitive: command['case-sensitive'] == true,
          snapshotId: command['id'],
          limit: int.tryParse(command['max']?.toString() ?? ''),
        );
        break;

      default:
        app.showHelp();
    }
  } catch (e) {
    print('❌ Error: $e');
  }
}
