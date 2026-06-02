import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' as crypto_alg;
import 'package:http/http.dart' as http;
import 'package:vcs/models/alias_manager.dart';
import 'package:vcs/models/ansi_string.dart';
import 'package:vcs/models/change_counts.dart';
import 'package:vcs/models/decrypted_snapshot.dart';
import 'package:vcs/models/diff_line.dart';
import 'package:vcs/models/file_change.dart';
import 'package:vcs/models/git_check.dart';
import 'package:vcs/models/hooks_manager.dart';
import 'package:vcs/models/ignore_rule.dart';
import 'package:vcs/models/index_service.dart';
import 'package:vcs/models/merge_report.dart';
import 'package:vcs/models/range.dart';
import 'package:vcs/models/release_meta.dart';
import 'package:vcs/models/repo_context.dart';
import 'package:vcs/models/repo_meta.dart';
import 'package:vcs/models/roadmap_model.dart';
import 'package:vcs/models/snapshot_log_entry.dart';
import 'package:vcs/models/snapshot_notes.dart';
import 'package:vcs/models/track_state.dart';
import 'package:vcs/models/tree_node.dart';
import 'package:vcs/models/update_cache.dart';
import 'package:vcs/models/version_history.dart';
import 'package:highlight/highlight.dart';
import 'package:highlight/languages/all.dart';
import 'package:vcs/services/cleanup_service.dart';
import 'package:vcs/services/history_parser.dart';
import 'package:vcs/services/release_service.dart';
import 'package:vcs/services/roadmap_manager.dart';
import 'package:vcs/services/snapshot_snadbox.dart';
import 'package:vcs/utils/progress_visualizer.dart';
import 'package:vcs/utils/reporter.dart';

enum LogViewMode { summary, standard, full}
enum RemoteStatus { synced, ahead, behind, diverged, unknown }
const String vcsBaseVersion = '0.4.6-Experimental.1';

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

  Directory? _forcedCwd;
  Directory get _cwd => _forcedCwd ?? Directory.current;
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

  void setShadowContext(String path) {
    _forcedCwd = Directory(path);
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
        showChangelog(targetVersion: detectedRemoteV);
      }

      if (Platform.isWindows) {
        final backupExe = File('$currentExePath.old');
        if (await backupExe.exists()) {
          try {
            await backupExe.delete();
            print('🧹 ${"Cleaned up legacy binary.".grey}');
          } catch (e) {
            print('💡 ${"Note:".yellow} Could not auto-delete ${".old".cyan} file. You can delete it manually. Use command `rm ${currentExePath}.old`');
          }
        }
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
    final String headerStr = " UPGRADE  New version available!";
    final String infoStr   = " ┃  $current → $latest";
    final String actionStr = " ┃  Run vcs update to install.";

    final int width = [headerStr.length, infoStr.length, actionStr.length]
        .reduce((a, b) => a > b ? a : b);

    print('');
    print('  ${" UPGRADE ".black.onYellow.bold} ${"New version available!".yellow}');
    print('  ${"┃".yellow.bold}  ${current.grey} → ${latest.green.bold}');
    print('  ${"┃".yellow.bold}  Run ${"vcs update".cyan.bold} to install.');
    print('  ${"━" * width}'.grey);
    print('');
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
    - `open [target]` Smart opener for projects and hardware.
      - `(no args)`      Opens the current directory in VS Code.
      - `usb`            Opens the root of the connected Vault drive.
      - `<name>`         Scans /USB/Local. If found on USB, opens the encrypted folder (even with random IDs).

    ## 🛤️ TRACKS MANAGEMENT
    - `track list` List all available tracks.
    - `track current` Show the name of the active track.
    - `track create <name>` Create a new track.
      - `-f, --from <id>` Optional: Branch from a specific snapshot ID.
    - `track switch <name>` Switch to another track.
    - `track delete <name>` Delete an existing non-active track.
    - `ancestry` Show the genealogical tree of snapshots (Lineage).
      - `-t, --track <name>` Visualize ancestry of a specific track.

    ## 📦 SNAPSHOT WORKFLOW
    - `push "message"` Create a snapshot (with parent tracking).
      - `-a, --author <name>` Override the author name for this snapshot.
      - `-t, --track <name>` Target a specific track instead of active.
      - `--amend` Overwrite the last snapshot (preserves lineage).
    - `tag <name>` Assign a friendly label to a snapshot.
      - `-i, --id <id>` Target a specific ID (defaults to latest).
      - `-t, --track <name>` Target a snapshot in a specific track.
    - `pull [id|tag]` Restore latest, specific ID or **tagged** snapshot.
      - `-t, --track <name>` Source snapshot from a specific track.
      - `--dry-run` Preview changes without applying.
    - `merge-apply <track>` Merge a target track into the active one.
      - `--id <id>` Specify a manual ancestor ID for 3-way merge.
      - Uses temporary sandboxes for 3-way conflict resolution and auditing.
    - `revert <id|tag>` Quick restore of a specific version from active track.
    - `restore <id|tag>` Restore a specific snapshot into another folder.
      - `--to <dir>` Destination path for the restored files.
    - `export --to <file.zip>` Package a snapshot into a portable .zip archive.
      - `-i, --id <id>` Target snapshot ID to export (defaults to latest).
    - `import --from <file.zip>` Import and track a project from a .zip file.
      - `-t, --track <name>` Target track for the imported project.

    ## 🚀 RELEASES (Public/Distribution)
    - `release create "message"` Create a portable, encrypted archive for distribution.
      - Prompts for version tag (e.g., v1.0.1) and repository password.
    - `release list` List all registered release versions and their IDs.
    - `release public [id]` Extract and run an isolated VS Code instance from a release.
      - Prompts for password to decrypt the archive into a volatile workspace.
    - `release delete [id]` Remove a release and its physical data from the vault.

    ## 🪝 AUTOMATION & HOOKS
    - `hook create <name>` Create a new automation script (.ps1, .bat, .sh).
      - `-c, --config <auto|man>` Set execution mode (default: man).
    - `hook edit <name>` Open a hook in the editor to modify code or config.
      - `-c, --config <auto|man>` Update the execution mode.
    - `hook exec <name>` Manually run a specific hook.
    - `hook delete <name>` Remove a hook configuration and its script file.

    ## 📝 SNAPSHOT ANNOTATIONS
    - `note "text"` Add a technical note or comment to a snapshot.
      - `--id <id>` Target a specific snapshot (defaults to latest).
      - `-a, --author <name>` Set a custom author for the note.
      - `-r, --remove` Remove a note (requires `--index`).
      - `-i, --index <n>` The index of the note to remove (from `log`).
      - `--all` Remove all notes from the target snapshot.

    ## 🗺️ STRATEGIC ROADMAP
    - `roadmap` (No args) Render the visual tree of milestones and tasks.
    - `roadmap init` Fast initial template setup for uninitiated projects.
    - `roadmap edit` Open the roadmap.json in your system editor for rapid batch modification.
    - `roadmap add <version> "title"` Append a new release block milestone.
    - `roadmap task <version> "desc"` Append an incremental task to a target version block.
      - `-g, --task-tag <tag>` Assign a short classification tag (e.g., CORE, PERF, BUG).
    - `roadmap done <task_id>` Toggle completion progress state (TODO|DONE) for a specific task.
    - `roadmap rm <version>` Remove a version milestone block and all its nested tasks.

    ## 🔍 INSPECTION & PERFORMANCE
    - `ui` Launch the Web Dashboard (Split-view diff support).
    - `inspect [id]` Deep audit of a snapshot's metadata, changes, and notes.
    - `status` Compare local tree vs latest of the active track.
    - `di` Inspect the pre-computed **Delta-Index** of a snapshot.
      - `-i, --id <id>` Target a specific snapshot (defaults to latest).
      - `-e, --ext <.ext>` Filter files by type (e.g., `vcs di --ext .dart`).
      - `-t, --track <name>` Target a specific track.
    - `timeline` Show an interactive or list-based chronological view.
      - `-t, --track <name>` Visualize a specific track.
      - `-n, --limit <n>` Number of snapshots to display (default: 15).
    - `search <query>` Search text inside encrypted snapshots.
      - `-t, --track <name>` Search only within a specific track.
      - `--id <snapshot_id>` Search only in a specific snapshot.
      - `-m, --max <n>` Search only in the last N snapshots.
      - `-s, --case-sensitive` Perform a case-sensitive search.
      - `--file <query>` Search for filenames or filter content search by path.
    - `info` Project overview, storage impact and activity charts.
      - `--charts` Display 7-day activity histogram.
    - `summary` Summary of messages to help create Git|GitHub commits.
    - `diff` Compare latest snapshot vs current live files.
      - `-f, --fast` Use high-speed mode using **Delta-Index**.
      - `--sandbox` Extract snapshots to temporary folders for manual audit.
    - `diff [id1] [id2|.]` Compare snapshots or snapshot vs working tree.
      - `-f, --fast` Enable index-based acceleration.
      - `-t, --tracks <tk1> <tk2>` Compare the last snapshot between two tracks.
      - `--sandbox` Provision isolated audit folders for 3-way conflict resolution.
    - `log` Show history of snapshots (includes **🏷️ Tags** and **📝 Notes**).
      - `--graph, -g` Visual representation of the snapshot timeline.
      - `--full` Show extended details (IDs, dates, metadata).
      - `--standard` Show summary with 5-file change preview.
      - `--summary` (Default) Show only statistics and message.
    - `show <id|tag>` Show details of a specific snapshot (including all notes).
    - `tree [id|tag]` Show visual file tree representation.
    - `verify <id|--all>` Verify cryptographic integrity and **index health**.

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
      - `--rebuild, -r` Physically scan the USB to reconstruct meta.json or missing indices.
      - `--reindex, -i` Retroactively regenerate missing Fast-Diff indices for legacy snapshots.
    - `stats` Show global repo metrics, track breakdown and **index coverage**.
    - `benchmark` Performance stress test (IOPS, Crypto & Transfer speed).
      - `-i, --intensive` Run a high-load test with larger data buffers.
    - `prune` Clean up old snapshots (Ancestry-safe):
      - `--id <id>` Delete a specific snapshot by its ID (cleans indices).
      - `--keep N` Keep only the newest N snapshots.
      - `--older-than N` Delete snapshots older than N days.
      - `--garbage` Deep clean: Remove orphaned data blobs and unused indices.
    - `clean` Purge all temporary audit sandboxes from the system.
    - `storage-check` Hardware diagnostic and latency test of the device.
      - `--full` Perform a more intensive read|write integrity check.
    - `migrate` Move your vault to a new drive or NAS:
      - `--to <path>` Target destination path for migration.
      - `--delete-source` Remove data from old drive after success.

    ## ⚙️ GENERAL
    - `help` Show this help message.
    - `version` Show tool version.
    - `changelog` Show changes of the version.
      - `--list, -l` Display the full version history index.

    ---

    ### 💡 PRO TIPS
    - **Hybrid Search:** Use `vcs search "TODO" --file "*.dart"` to only decrypt and scan Dart files, making the search much faster.
    - **Delta-Index Acceleration:** Use the `-f` flag in `diff` and `search` to leverage pre-computed indices and avoid unnecessary decryption.
    - **Ancestry Tracking:** Use `vcs ancestry` to understand the origin of your current track and its relation to others.
    - **Human-readable IDs:** Use `vcs tag stable` to avoid typing long IDs in `pull` or `diff`.
    - **Data Resilience:** The `doctor --rebuild` command can restore metadata and indices by scanning physical storage.
    - **USB Aliases:** Aliases are stored in the USB root, so they follow you to any computer.
    - All data is **AES-256 encrypted**. Keep your vault password safe.

    ''';

    print(_renderMarkdown(helpMarkdown));
  }

  void showChangelog({String? targetVersion, bool interactive = false}) {
    if (interactive) {
      final String listMarkdown = VersionHistory.getAvailableVersionsMarkdown();
      print(_renderMarkdown(listMarkdown));
      
      stdout.write('👉 ');
      final input = stdin.readLineSync()?.trim().toLowerCase();

      if (input == null || input == 'q') return;

      final index = int.tryParse(input);
      final versions = VersionHistory.allVersions;

      if (index != null && index > 0 && index <= versions.length) {
        print('\x1B[2J\x1B[0;0H'); 
        showChangelog(targetVersion: versions[index - 1]);
      } else {
        print('❌ Invalid selection.'.red);
      }
      return;
    }

    final String versionToShow = targetVersion ?? vcsBaseVersion;
    final String content = VersionHistory.getMarkdown(versionToShow);
    
    final String changelogMarkdown = '''
  # 📜 CHANGELOG [[ V.$versionToShow ]]

  > What's new in this release? Here is a summary of the latest changes.

  $content

  ---
  ### 💡 INFO
  - You are currently running the **Experimental** branch.
  - Type `vcs changelog --list` to see previous versions.
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

    final Map<String, String> languageTemplates = {
      'pubspec.yaml': '.dart_tool/\n.packages\n.pub-cache/\nbuild/\n*.exe\n*.zip',
      'lib/main.dart': '.dart_tool/\n.packages\n.pub-cache/\nbuild/\n*.exe\n*.apk\n*.ipa',
      'package.json': 'node_modules/\ndist/\nbuild/\n.env\n*.log\ncoverage/',
      'requirements.txt': '__pycache__/\n*.pyc\n.venv/\nvenv/\n.env\n.pytest_cache/',
      'pom.xml': 'target/\n.settings/\n.project\n.classpath\n.idea/',
      'go.mod': 'bin/\nobj/\n*.exe\n*.test\n*.out',
      'Cargo.toml': 'target/\ndebug/\nrelease/\n*.rs.bk',
      'build.gradle': '.gradle/\nbuild/\n.settings/\n.project',
      'composer.json': 'vendor/\n.env\n*.log',
      'index.php': 'vendor/\nnode_modules/\n.env\n*.log',
      'CMakeLists.txt': 'build/\n*.o\n*.a\n*.so\n*.out',
      'Makefile': '*.o\n*.out\n*.exe\nbuild/',
      'Gemfile': '.bundle/\nvendor/bundle/\nlog/\n*.log\n.env',
      '*.csproj': 'bin/\nobj/\n*.user\n*.suo\n.vs/',
      'docker-compose.yml': '.env\n*.log\ndata/\nvolumes/',
      'Assets/': 'Library/\nTemp/\nObj/\nBuild/\nLogs/',
      'pyproject.toml': '.venv/\n.pytest_cache/\n.tox/\nbuild/\ndist/',
      'tsconfig.json': 'node_modules/\ndist/\nbuild/\n*.tsbuildinfo',
      'podfile': 'Pods/\n*.framework\n*.xcworkspace/',
      'app.json': '.expo/\n.next/\nout/\n.env',
      '*.sql': '*.log\n*.dump\n*.sqlite\n*.sqlite-journal',
      'nuxt.config.js': '.nuxt/\n.output/\n.env\nnode_modules/'
    };

    final gitIgnoreFile = File(p.join(_cwd.path, '.gitignore'));
    if (!gitIgnoreFile.existsSync()) {
      String? detectedTemplate;
      String? detectedLanguage;

      for (var entry in languageTemplates.entries) {
        if (File(p.join(_cwd.path, entry.key)).existsSync()) {
          detectedLanguage = entry.key;
          detectedTemplate = entry.value;
          break;
        }
      }

      if (detectedTemplate != null) {
        print('\n💡 ${"Detected project type:".yellow} $detectedLanguage');
        if (confirmAction('✨ Generate recommended .gitignore?')) {
          await gitIgnoreFile.writeAsString(detectedTemplate);
          print('✅ ${".gitignore created successfully.".green}');
          print('   ${"Files ignored:".grey} ${detectedTemplate.replaceAll('\n', ', ')}');
        }
      }
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
      if (!confirmAction('Bind anyway?')) {
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

  Future<void> status({String? password, showIgnored = false}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrackName = context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrackName];

    print('\n🔍 ${"WORKING TREE STATUS".black.onCyan}');
    print('${"On track:".yellow} ${targetTrackName.magenta.bold}');

    final rawFingerprint = await buildFingerprint(_cwd);
    var currentFingerprint = <String, String>{};

    for (final entry in rawFingerprint.entries) {
      try {
        final file = File(p.join(_cwd.path, entry.key));
        if (file.existsSync()) {
          final canonical = p.relative(file.resolveSymbolicLinksSync(), from: _cwd.resolveSymbolicLinksSync());
          currentFingerprint[p.normalize(canonical).replaceAll('\\', '/')] = entry.value;
        } else {
          currentFingerprint[p.normalize(entry.key).replaceAll('\\', '/')] = entry.value;
        }
      } catch (_) {
        currentFingerprint[p.normalize(entry.key).replaceAll('\\', '/')] = entry.value;
      }
    }

    final gitignoreFile = File(p.join(_cwd.path, '.gitignore'));
    List<String> explicitlyIgnoredFiles = [];
    if (gitignoreFile.existsSync()) {
      try {
        final lines = await gitignoreFile.readAsLines();
        final List<IgnoreRule> compiledRules = [];
        for (final line in lines) {
          final rule = IgnoreRule.parse(line);
          if (rule != null) compiledRules.add(rule);
        }
        compiledRules.add(IgnoreRule.parse('.vcs')!);
        compiledRules.add(IgnoreRule.parse('.vcs/')!);

        currentFingerprint = Map.fromEntries(
          currentFingerprint.entries.where((entry) {
            final relativePath = entry.key;
            final basename = p.basename(relativePath);
            
            bool isIgnored = false;
            for (final rule in compiledRules) {
              if (rule.matches(relativePath, basename)) {
                isIgnored = !rule.negated;
              }
            }

            if (isIgnored) {
              if (showIgnored) explicitlyIgnoredFiles.add(relativePath);
              return false;
            }
            return true;
          }),
        );
      } catch (e) {
        print('⚠️ ${"Warning: Error evaluating exclusion rules: $e".yellow}');
      }
    }

    if (trackData == null || trackData.logs.isEmpty) {
      if (currentFingerprint.isEmpty) {
        print('\n✨ ${"Empty project. Nothing to track.".grey}');
        return;
      }
      print('\n${"Untracked files (Initial commit):".bold}');
      print('  ${"(use \"vcs push <message>\" to create the initial snapshot)".grey}');
      for (final path in (currentFingerprint.keys.toList()..sort())) {
        print('    ${'NEW'.black.onGreen.padRight(7)} $path');
      }
      return;
    }

    final lastEntry = trackData.logs.first;
    Map<String, String>? lastFingerprint = await IndexService.loadSnapshotIndex(
      context.remoteRepoDir, 
      lastEntry.id
    );

    if (lastFingerprint == null) {
      print('ℹ️  ${"Fast-index missing. Reconstructing from snapshot...".grey}');
      String? finalPassword = password;
      if (finalPassword == null && context.remoteMeta.formatVersion >= 3) {
        finalPassword = askPassword();
      }
      if (finalPassword == null && context.remoteMeta.formatVersion >= 3) {
        print('❌ ${"Password required for legacy snapshots in v3+ repositories.".red}');
        return;
      }
      final snapshot = await readSnapshot(context, lastEntry.id, password: finalPassword ?? '');
      if (snapshot == null) {
        print('❌ ${"Could not read snapshot data for comparison.".red}');
        return;
      }
      lastFingerprint = Map<String, String>.from(snapshot.fingerprint);
    }

    final cleanLastFingerprint = lastFingerprint.map(
      (key, value) => MapEntry(p.normalize(key).replaceAll('\\', '/'), value)
    );

    final changes = diffFingerprints(cleanLastFingerprint, currentFingerprint);
    final lastSnapshotDate = DateTime.parse(lastEntry.createdAt);
    final daysOld = DateTime.now().difference(lastSnapshotDate).inDays;

    bool hasDrift = changes.isNotEmpty;

    int totalBytes = 0;
    for (final change in changes) {
      if (change.kind == ChangeKind.added || change.kind == ChangeKind.modified) {
        try {
          final file = File(p.join(_cwd.path, change.path));
          if (file.existsSync()) totalBytes += await file.length();
        } catch (_) {}
      }
    }
    String sizeLabel = totalBytes < 1024 * 1024 
        ? '${(totalBytes / 1024).toStringAsFixed(1)} KB' 
        : '${(totalBytes / (1024 * 1024)).toStringAsFixed(2)} MB';

    if (hasDrift) {
      print(' ⚠️  ${"DRIFT DETECTED: Workspace is out of sync with HEAD".red.bold}');
      print('    ${"Some files have diverged from the last snapshot.".grey}');
    } else {
      print('\n✨ ${"Working tree clean.".green}');
      print('${"Your project is up to date with track".grey} ${targetTrackName.cyan}.');
      return;
    }

    Map<String, List<FileChange>> groups = {
      '🛠️  LOGIC': [], '🧪  TESTS': [], '🎨  ASSETS': [],
      '⚙️  CONFIG': [], 'ℹ️ DOCS': [], '📄  OTHER': [],
    };

    for (final change in changes) {
      final ext = p.extension(change.path).toLowerCase();
      final fileName = p.basename(change.path).toLowerCase();
      final pathSegments = p.split(change.path).map((s) => s.toLowerCase()).toList();

      if (fileName.contains('_test.') || fileName.contains('.spec.') || pathSegments.contains('test') || pathSegments.contains('test_driver')) {
        groups['🧪  TESTS']!.add(change);
      } else if (['.dart', '.js', '.py', '.cpp', '.h', '.ts', '.go', '.rs', '.php', '.c', '.java', '.kt', '.swift', '.cs'].contains(ext)) {
        groups['🛠️  LOGIC']!.add(change);
      } else if (['.png', '.jpg', '.jpeg', '.svg', '.gif', '.webp', '.ico', '.mp4', '.wav', '.mp3', '.ttf', '.otf', '.woff', '.woff2'].contains(ext)) {
        groups['🎨  ASSETS']!.add(change);
      } else if (['.yaml', '.json', '.xml', '.toml', '.lock', '.gradle', '.plist', '.properties', '.conf', '.ini', '.env'].contains(ext) || fileName == 'dockerfile' || fileName == 'makefile') {
        groups['⚙️  CONFIG']!.add(change);
      } else if (['.md', '.adoc', '.rst', '.txt'].contains(ext) || fileName == 'license' || fileName == 'changelog' || fileName == 'readme') {
        groups['ℹ️ DOCS']!.add(change);
      } else {
        groups['📄  OTHER']!.add(change);
      }
    }

    if (showIgnored) {
      print('\n${'--- 🚫 Ignored Files ---'.cyan}');
      if (explicitlyIgnoredFiles.isEmpty) {
        print('   ${"(No bypassed files detected in the workspace)".grey.italic}');
      } else {
        explicitlyIgnoredFiles.sort();
        for (final path in explicitlyIgnoredFiles) print('   ${'[I]'.grey} ${path.gray}');
        print('\n   ${explicitlyIgnoredFiles.length.toString().grey} files currently excluded by rules.');
      }
      print('  ' + '─' * 45 + '\n');
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
          case ChangeKind.added: label = 'NEW'.black.onGreen; coloredPath = change.path.green; added++; break;
          case ChangeKind.modified: label = 'MOD'.black.onYellow; coloredPath = change.path.yellow; modified++; break;
          case ChangeKind.deleted: label = 'DEL'.black.onRed; coloredPath = change.path.red; deleted++; break;
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
    print('  ${"Stale:".magenta} ${"$daysOld days since last snapshot".yellow}');
    print('  ${"Impact:".magenta} ${"~$sizeLabel for next push".yellow}');
    print('  ' + '─' * 45 + '\n');
  }

  Future<void> search(
    String query, {
    String? track,
    bool caseSensitive = false,
    String? snapshotId,
    int? limit,
    String? fileQuery,
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

    final String? cleanQuery = query.trim().isEmpty ? null : (caseSensitive ? query : query.toLowerCase());

    if (cleanQuery != null) {
      print('\n🔍 ${" SEARCHING METADATA & NOTES ".black.onCyan}');
      bool foundInMeta = false;
      for (final entry in logsToSearch) {
        bool matchInEntry = false;
        final msg = caseSensitive ? entry.message : entry.message.toLowerCase();

        if (msg.contains(cleanQuery)) {
          print('\n📌 ${"Match in Snapshot Message:".cyan} ${entry.id.green}');
          print('   > ${entry.message.white.italic}');
          matchInEntry = true;
        }

        for (int i = 0; i < entry.notes.length; i++) {
          final note = entry.notes[i];
          final noteText = caseSensitive ? note.text : note.text.toLowerCase();
          if (noteText.contains(cleanQuery)) {
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
      if (!foundInMeta) print('  ${"No matches found in messages or notes.".grey}');
    }

    int legacyCount = 0;
    if (fileQuery != null) {
      print('\n📂 ${" SEARCHING FOR FILES ".black.onMagenta}');
      final fQuery = caseSensitive ? fileQuery : fileQuery.toLowerCase();
      bool fileFound = false;

      for (final entry in logsToSearch) {
        final index = await IndexService.loadSnapshotIndex(context.remoteRepoDir, entry.id);
        if (index == null) {
          legacyCount++;
          continue;
        }

        final matchingFiles = index.keys.where((path) {
          final target = caseSensitive ? path : path.toLowerCase();
          return target.contains(fQuery);
        }).toList();

        if (matchingFiles.isNotEmpty) {
          print('\n📦 In Snapshot: ${entry.id.green} (${entry.message.grey})');
          for (var f in matchingFiles) print('   📄 $f');
          fileFound = true;
        }
      }
      if (legacyCount > 0) {
        print('\nℹ️  $legacyCount snapshots are legacy (no delta-index).');
        print('   ${"Names in those snapshots will be checked during Deep Search.".grey}');
      }
      if (!fileFound && legacyCount == 0) print('  ${"No files matching '$fileQuery' found.".grey}');
    }

    if (cleanQuery == null && legacyCount == 0) {
      print('\n✅ ${"Search finished.".green}');
      return;
    }

    print('\n🚀 ${" PROCEED TO DEEP SEARCH? ".black.onYellow}');
    stdout.write(cleanQuery != null ? 'Search for content? (y/N): ' : 'Check legacy snapshots for files? (y/N): ');
    if ((stdin.readLineSync() ?? '').trim().toLowerCase() != 'y') return;

    final password = askPassword();
    if (password == null || password.isEmpty) return;

    print('\n🔍 ${" DEEP SEARCH ".black.onCyan}');
    print('═' * 60);

    int totalMatches = 0;
    int snapshotsWithMatches = 0;

    for (final entry in logsToSearch) {
      final sId = entry.id.toString();
      final shortId = sId.length > 8 ? sId.substring(0, 8) : sId;
      final index = await IndexService.loadSnapshotIndex(context.remoteRepoDir, sId);

      if (fileQuery != null && index != null) {
        final fQuery = caseSensitive ? fileQuery : fileQuery.toLowerCase();
        if (!index.keys.any((p) => (caseSensitive ? p : p.toLowerCase()).contains(fQuery))) continue;
      }

      if (cleanQuery == null && index != null) continue;

      stdout.write('⏳ ${"Processing:".grey} ${shortId.cyan}...\r');

      try {
        final snapshot = await readSnapshot(context, sId, password: password);
        if (snapshot == null) continue;
        final files = await _decodeSnapshotFiles(snapshot);
        bool snapshotHasMatch = false;

        for (final fileName in files.keys) {
          if (fileQuery != null) {
            final target = caseSensitive ? fileName : fileName.toLowerCase();
            if (!target.contains(caseSensitive ? fileQuery : fileQuery.toLowerCase())) continue;
          }

          if (cleanQuery == null) {
            if (!snapshotHasMatch) {
              stdout.write(' ' * 45 + '\r');
              print('\n📦 Snapshot: ${sId.green} [${entry.message.grey}]');
              snapshotHasMatch = true;
              snapshotsWithMatches++;
            }
            print('   📄 ${fileName.yellow}');
            totalMatches++;
            continue;
          }

          final bytes = files[fileName]!;
          if (_isBinaryFile(fileName, bytes)) continue;
          final content = utf8.decode(bytes, allowMalformed: true);
          final contentSearchable = caseSensitive ? content : content.toLowerCase();

          if (contentSearchable.contains(cleanQuery)) {
            final lines = content.split('\n');
            for (int i = 0; i < lines.length; i++) {
              final lineSearchable = caseSensitive ? lines[i] : lines[i].toLowerCase();
              if (lineSearchable.contains(cleanQuery)) {
                if (!snapshotHasMatch) {
                  stdout.write(' ' * 45 + '\r');
                  print('\n📦 Snapshot: ${sId.green} [${entry.message.grey}]');
                  snapshotHasMatch = true;
                  snapshotsWithMatches++;
                }
                print('   📄 ${fileName.yellow}:${(i + 1).toString().white}');
                _printSmartContext(lines, i, query, caseSensitive);
                totalMatches++;
                print('      ' + '┈' * 45);
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
      stdout.write(' ' * 45 + '\r');
      print('Status: ${"No matches found.".yellow}');
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

    final bool isFast = args.contains('--fast') || args.contains('-f');
    final bool useSandbox = args.contains('--sandbox');
    final cleanArgs = args.where((a) => 
      a != '--fast' && 
      a != '-f' && 
      a != '--sandbox'
    ).toList();

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
      if (isFast) {
        print('⚡ ${"FAST DIFF MODE".black.onYellow} (Metadata comparison)');
        
        Map<String, String>? leftMap;
        Map<String, String>? rightMap;
        String leftLabel = "";
        String rightLabel = "";

        if (cleanArgs.isEmpty) {
          final trackLogs = context.remoteMeta.tracks[context.remoteMeta.activeTrack]?.logs ?? [];
          if (trackLogs.isEmpty) {
            print('ℹ️ No snapshots available to compare.'.yellow);
            return;
          }
          final latestId = trackLogs.first.id;
          leftMap = await IndexService.loadSnapshotIndex(context.remoteRepoDir, latestId);
          rightMap = await buildFingerprint(_cwd);
          leftLabel = 'snapshot:$latestId (latest)';
          rightLabel = 'working-tree (live)';
        } 
        else if (cleanArgs.length == 1) {
          final id = resolveId(cleanArgs[0]);
          if (id == null) return;
          leftMap = await IndexService.loadSnapshotIndex(context.remoteRepoDir, id);
          rightMap = await buildFingerprint(_cwd);
          leftLabel = 'snapshot:$id';
          rightLabel = 'working-tree (live)';
        } 
        else if (cleanArgs.length == 2) {
          final idLeft = resolveId(cleanArgs[0]);
          if (idLeft == null) return;
          leftMap = await IndexService.loadSnapshotIndex(context.remoteRepoDir, idLeft);
          leftLabel = 'snapshot:$idLeft';

          if (cleanArgs[1] == '.') {
            rightMap = await buildFingerprint(_cwd);
            rightLabel = 'working-tree (live)';
          } else {
            final idRight = resolveId(cleanArgs[1]);
            if (idRight == null) return;
            rightMap = await IndexService.loadSnapshotIndex(context.remoteRepoDir, idRight);
            rightLabel = 'snapshot:$idRight';
          }
        }

        if (leftMap == null || rightMap == null) {
          print('❌ Could not load index for fast diff. Make sure snapshots were created with v0.3.9+.'.red);
          return;
        }

        _printFastDiff(leftMap, rightMap, leftLabel, rightLabel);
        return;
      }
      
      final finalPassword = password ?? askPassword();
      if (finalPassword == null || finalPassword.isEmpty) {
        print('❌ Password required for full content diff.');
        return;
      }

      late final Map<String, Uint8List> leftFiles;
      late final Map<String, Uint8List> rightFiles;
      late final String leftLabel;
      late final String rightLabel;

      bool isThreeWay = cleanArgs.length == 3;
      if (cleanArgs.length == 2 && 
          context.remoteMeta.tracks.containsKey(cleanArgs[0]) && 
          context.remoteMeta.tracks.containsKey(cleanArgs[1])) {
        isThreeWay = true;
      }

      if (isThreeWay) {
        final idLeft = resolveId(cleanArgs[0]);
        final idRight = resolveId(cleanArgs.length == 3 ? cleanArgs[2] : cleanArgs[1]);
        String? idBase = cleanArgs.length == 3 ? resolveId(cleanArgs[1]) : null;

        if (idLeft == null || idRight == null) return;

        if (idBase == null) {
          final allLogs = context.remoteMeta.tracks.values.expand((t) => t.logs).toList();
          final analyzer = HistoryParser(allLogs);
          idBase = analyzer.findCommonAncestor(idLeft, idRight);
        }

        if (idBase == null) {
          print('⚠️ No common ancestor found. Falling back to standard diff.'.yellow);
        } else {
          print('🔍 ${"Analyzing 3-way diff...".cyan}');
          print('📂 ${"Base:".grey} $idBase | ${"Left:".blue} $idLeft | ${"Right:".magenta} $idRight');

          final baseSnap = await readSnapshot(context, idBase, password: finalPassword);
          final leftSnap = await readSnapshot(context, idLeft, password: finalPassword);
          final rightSnap = await readSnapshot(context, idRight, password: finalPassword);

          if (baseSnap == null || leftSnap == null || rightSnap == null) return;

          if (useSandbox) {
            print('🏗️ ${"Provisioning sandboxes for audit...".cyan}');
            final sandbox = SnapshotSandbox(context.remoteRepoDir);            
            final dirBase = await sandbox.provision(idBase!, baseSnap);
            final dirLeft = await sandbox.provision(idLeft!, leftSnap);
            final dirRight = await sandbox.provision(idRight!, rightSnap);
            
            print('📍 Base Sandbox: ${dirBase.path.grey}');
            print('📍 Left Sandbox: ${dirLeft.path.grey}');
            print('📍 Right Sandbox: ${dirRight.path.grey}');
            print('✨ ${"Sandboxes ready.".green}');
          }

          await _print3WayDiff(
            await _decodeSnapshotFiles(baseSnap),
            await _decodeSnapshotFiles(leftSnap),
            await _decodeSnapshotFiles(rightSnap),
            labels: [idBase, idLeft, idRight],
          );
          return;
        }
      }

      if (cleanArgs.isEmpty) {
        final trackLogs = context.remoteMeta.tracks[context.remoteMeta.activeTrack]?.logs ?? [];
        if (trackLogs.isEmpty) {
          print('ℹ️ No snapshots available in active track.'.yellow);
          return;
        }
        final latestId = trackLogs.first.id;
        final snapshot = await readSnapshot(context, latestId, password: finalPassword);
        if (snapshot == null) return;

        leftFiles = await _decodeSnapshotFiles(snapshot);
        rightFiles = await _readCurrentProjectFiles();
        leftLabel = 'snapshot:$latestId (latest)';
        rightLabel = 'working-tree (live)';
      } 
      else if (cleanArgs.length == 1) {
        final id = resolveId(cleanArgs[0]);
        if (id == null) return;

        final snapshot = await readSnapshot(context, id, password: finalPassword);
        if (snapshot == null) return;

        leftFiles = await _decodeSnapshotFiles(snapshot);
        rightFiles = await _readCurrentProjectFiles();
        leftLabel = 'snapshot:$id';
        rightLabel = 'working-tree (live)';
      } 
      else if (cleanArgs.length == 2) {
        final idLeft = resolveId(cleanArgs[0]);
        if (idLeft == null) return;
        final leftSnapshot = await readSnapshot(context, idLeft, password: finalPassword);
        if (leftSnapshot == null) return;
        leftFiles = await _decodeSnapshotFiles(leftSnapshot);
        leftLabel = 'snapshot:$idLeft';

        if (cleanArgs[1] == '.') {
          rightFiles = await _readCurrentProjectFiles();
          rightLabel = 'working-tree (live)';
        } else {
          final idRight = resolveId(cleanArgs[1]);
          if (idRight == null) return;
          final rightSnapshot = await readSnapshot(context, idRight, password: finalPassword);
          if (rightSnapshot == null) return;
          rightFiles = await _decodeSnapshotFiles(rightSnapshot);
          rightLabel = 'snapshot:$idRight';
        }
      } 
      else {
        print('❌ Usage: vcs diff [--fast] [id_or_track_1] [id_or_track_2 | .]'.red);
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

  void _printFastDiff(Map<String, String> left, Map<String, String> right, String lLab, String rLab) {
    final changes = diffFingerprints(left, right);

    print('\n${"Comparing:".grey} $lLab ${"<->".cyan} $rLab');

    if (changes.isEmpty) {
      print('\n✨ ${"No file structure changes detected (hashes match).".green}');
      return;
    }

    int added = 0, modified = 0, deleted = 0;

    print('\n${"Structural Changes:".bold}');
    final sortedChanges = changes..sort((a, b) => a.path.compareTo(b.path));
    
    for (final change in sortedChanges) {
      switch (change.kind) {
        case ChangeKind.added:
          print('  ${"[+]".green} ${change.path}');
          added++;
          break;
        case ChangeKind.modified:
          print('  ${"[~]".yellow} ${change.path}');
          modified++;
          break;
        case ChangeKind.deleted:
          print('  ${"[-]".red} ${change.path}');
          deleted++;
          break;
      }
    }

    print('\n${"Summary:".cyan} $added added, $modified modified, $deleted deleted.');
    print('${"Note: Use without --fast to see line-by-line content differences.".grey}');
  }

  Future<void> _print3WayDiff(
    Map<String, Uint8List> base, 
    Map<String, Uint8List> left, 
    Map<String, Uint8List> right,
    {required List<String> labels}
  ) async {
    final allPaths = {...base.keys, ...left.keys, ...right.keys}.toList()..sort();
    
    print('\n${"--- 3-WAY ANALYSIS REPORT ---".bold.cyan}');
    
    for (final path in allPaths) {
      final inBase = base.containsKey(path);
      final inLeft = left.containsKey(path);
      final inRight = right.containsKey(path);

      final contentBase = inBase ? base[path] : null;
      final contentLeft = inLeft ? left[path] : null;
      final contentRight = inRight ? right[path] : null;

      final changedLeft = _bytesEquals(contentBase, contentLeft) == false;
      final changedRight = _bytesEquals(contentBase, contentRight) == false;

      if (changedLeft && changedRight) {
        if (_bytesEquals(contentLeft, contentRight)) {
          print(' ${"=".grey} $path (Modified identically in both)');
        } else {
          print(' ${"⚠".red.bold} $path (CONFLICT: Modified in both with different results)');
        }
      } else if (changedLeft) {
        print(' ${"←".blue} $path (Modified in ${labels[1]} only)');
      } else if (changedRight) {
        print(' ${"→".magenta} $path (Modified in ${labels[2]} only)');
      }
    }
    print('\n${"------------------------------".cyan}');
  }

  bool _bytesEquals(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == b;
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String? _findCommonAncestor(RepoContext context, String id1, String id2) {
    final history1 = <String>{};

    final allLogs = <String, SnapshotLogEntry>{};
    for (var track in context.remoteMeta.tracks.values) {
      for (var log in track.logs) {
        allLogs[log.id] = log;
      }
    }

    String? current = id1;
    while (current != null) {
      history1.add(current);
      current = allLogs[current]?.parentId;
    }

    current = id2;
    while (current != null) {
      if (history1.contains(current)) return current;
      current = allLogs[current]?.parentId;
    }

    return null;
  }

  Future<bool> _hasEnoughStorageSpace(Directory targetDir, int requiredBytes) async {
    try {
      final path = targetDir.absolute.path;
      int freeBytes = -1;

      if (Platform.isWindows) {
        if (path.startsWith(r'\\')) {
          final result = await Process.run('fsutil', ['volume', 'diskfree', path], runInShell: true);
          if (result.exitCode == 0) {
            final output = result.stdout.toString();
            final freeMatch = RegExp(r':\s+([\d.]+)\s+\(').firstMatch(output);
            if (freeMatch != null) {
              freeBytes = int.tryParse(freeMatch.group(1)!.replaceAll('.', '')) ?? -1;
            }
          }
        } else {
          final drive = path.split(':').first + ':';
          final result = await Process.run('wmic', ['logicaldisk', 'where', 'DeviceID="$drive"', 'get', 'FreeSpace']);
          if (result.exitCode == 0) {
            final lines = result.stdout.toString().split('\n');
            for (var line in lines) {
              final trimmed = line.trim();
              if (trimmed.isNotEmpty && RegExp(r'^\d+$').hasMatch(trimmed)) {
                freeBytes = int.tryParse(trimmed) ?? -1;
                break;
              }
            }
          }
        }
      } else {
        final result = await Process.run('df', ['-B1', path]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split('\n');
          if (lines.length >= 2) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 4) freeBytes = int.tryParse(parts[3]) ?? -1;
          }
        }
      }

      if (freeBytes != -1 && freeBytes < requiredBytes) {
        final freeMb = freeBytes / (1024 * 1024);
        final reqMb = requiredBytes / (1024 * 1024);
        print('\n❌ ${"STORAGE ERROR: Insufficient disk space on ${path.startsWith(r'\\') ? 'Network' : 'Local'} drive.".red.bold}');
        print('   Required: ${reqMb.toStringAsFixed(2).yellow} MB');
        print('   Available: ${freeMb.toStringAsFixed(2).red} MB');
        print('   Target: ${path.grey}\n');
        return false;
      }
    } catch (e) {
      // Silent Error
      return true; 
    }
    return true;
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

    final metaFile = File(p.join(context.remoteRepoDir.path, 'meta.json'));
    try {
      if (metaFile.existsSync()) jsonDecode(await metaFile.readAsString());
    } catch (_) {
      print('❌ ${"Repository metadata is corrupt. Run 'vcs doctor' before pushing.".red}');
      return;
    }

    Directory workingDir = _cwd;
    if (overrideSourcePath != null) {
      workingDir = Directory(overrideSourcePath);
    }
    String targetTrackName = track ?? context.remoteMeta.activeTrack;

    final sessionFile = File(p.join(context.remoteRepoDir.path, 'session.json'));

    if (overrideSourcePath != null) {
      workingDir = Directory(overrideSourcePath);
    } else if (sessionFile.existsSync()) {
      try {
        final sessionData = jsonDecode(await sessionFile.readAsString());
        workingDir = Directory(sessionData['shadow_path']);
        targetTrackName = track ?? sessionData['active_shadow_track'];
        if (!skipConfirm) {
          print('🔍 ${"Shadow Session detected:".cyan} Pushing from ${workingDir.path}');
        }
      } catch (_) {}
    }

    final trackData = context.remoteMeta.tracks[targetTrackName];
    if (trackData == null) {
      print('❌ Track "$targetTrackName" does not exist.');
      return;
    }

    if (amend) {
      if (trackData.logs.isEmpty) {
        print('❌ ${"Cannot use --amend:".red} Track "$targetTrackName" has no history.');
        return;
      }

      final lastId = trackData.logs.first.id;
      final tagsLinked = context.remoteMeta.tags.entries
          .where((e) => e.value == lastId)
          .map((e) => e.key)
          .toList();

      if (tagsLinked.isNotEmpty) {
        print('❌ ${"Amend Blocked:".red} Latest snapshot is immutable because it is tagged.');
        print('🏷️  Tags found: ${tagsLinked.join(', ').magenta}');
        print('💡 Tip: Remove the tags or create a new snapshot instead.');
        return;
      }
    }

    final finalPassword = password ?? askPassword();
    if (finalPassword == null || finalPassword.isEmpty) {
      print('❌ Password required for encryption.');
      return;
    }

    await _withLock(context.remoteRepoDir, () async {
      final cacheFile = File(p.join(context.remoteRepoDir.path, '.vcs_cache.json'));
      Map<String, String>? cache;
      if (cacheFile.existsSync()) {
        try {
          final Map<String, dynamic> rawData = jsonDecode(await cacheFile.readAsString());
          cache = rawData.map((key, value) => MapEntry(key, value.toString()));
        } catch (_) {}
      }

      final currentFingerprint = await buildFingerprint(
        workingDir, 
        previousFingerprint: cache,
      );  
      await cacheFile.writeAsString(jsonEncode(currentFingerprint));

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
            lastFingerprint = lastSnapshot.fingerprint.map((key, value) {
              final parts = value.split('|');
              final normalizedValue = parts.length >= 3 ? '${parts[0]}|${parts[1]}' : value;
              return MapEntry(p.normalize(key).replaceAll('\\', '/'), normalizedValue);
            });
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
          switch (change.kind) {
            case ChangeKind.added:
              added++;
              print('  ${"[+]".green} ${change.path}');
              break;
            case ChangeKind.modified:
              modified++;
              print('  ${"[~]".yellow} ${change.path}');
              break;
            case ChangeKind.deleted:
              deleted++;
              print('  ${"[-]".red} ${change.path}');
              break;
          }
        }

        print('\nSummary: ${added.toString().green} added, ${modified.toString().yellow} modified, ${deleted.toString().red} deleted.');

        stdout.write('\nDo you want to proceed? (y/N): ');
        if ((stdin.readLineSync()?.trim().toLowerCase() ?? 'n') != 'y') return;
      }
      
      String? parentId;
      if (amend) {
        parentId = trackData.logs.length > 1 ? trackData.logs[1].id : trackData.originSnapshotId;
      } else {
        parentId = trackData.logs.isNotEmpty ? trackData.logs.first.id : trackData.originSnapshotId;
      }
      
      if (amend) {
        final oldSnapshot = trackData.logs.first;
        final oldFile = File(p.join(context.remoteRepoDir.path, 'snapshots', oldSnapshot.fileName));
        
        if (oldFile.existsSync()) {
          await oldFile.delete();
        }

        try {
          await IndexService.deleteSnapshotIndex(
            remoteRepoDir: context.remoteRepoDir,
            snapshotId: oldSnapshot.id,
          );
        } catch (e) {
          // No critical error
        }
      }

      final hookContext = {
        'VCS_SNAPSHOT_ID': DateTime.now().millisecondsSinceEpoch.toString(),
        'VCS_TRACK': targetTrackName,
        'VCS_AUTHOR': author ?? 'unknown',
        'VCS_VERSION': vcsBaseVersion,
      };

      if (!(await HookManager.runAutoHooks(context, extraEnv: hookContext))) {
        print('❌ Push aborted by automation hook.');
        return;
      }

      print('📦 Packing and encrypting...');
      final zipBytes = await _createZipFromCurrentProject(sourcePath: workingDir);

      try {
        print('🛡️ Running integrity verification...');
        ZipDecoder().decodeBytes(zipBytes, verify: true);
        print('✅ ${"Integrity check passed (ZIP valid).".green}');
      } catch (e) {
        print('\n❌ ${"CRITICAL: Integrity check failed!".red} $e');
        return;
      }

      final int estimatedEncryptedSize = zipBytes.length + (64 * 1024);

      if (!await _hasEnoughStorageSpace(context.remoteRepoDir, estimatedEncryptedSize)) {
        print('❌ Push aborted: Storage drive is full.'.red);
        return;
      }

      final encrypted = await _encryptSnapshot(
        zipBytes: zipBytes,
        message: message,
        author: author,
        fingerprint: currentFingerprint,
        password: finalPassword,
        trackName: targetTrackName,
        parentId: parentId,
      );

      final snapshotId = DateTime.now().millisecondsSinceEpoch.toString();
      final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
      if (!snapshotsDir.existsSync()) await snapshotsDir.create(recursive: true);

      final finalFile = File(p.join(snapshotsDir.path, '$snapshotId.vcs'));
      String? fileHash;

      final visualizer = ProgressVisualizer(
        label: 'Writing to Vault',
        totalBytes: encrypted.length,
      );

      Stream<List<int>> chunkedStream(List<int> data, int chunkSize) async* {
        for (var i = 0; i < data.length; i += chunkSize) {
          final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
          yield data.sublist(i, end);
          await Future.delayed(Duration.zero); 
        }
      }

      try {
        final sink = finalFile.openWrite();
        await chunkedStream(encrypted, 64 * 1024)
            .withProgress(visualizer)
            .pipe(sink);

        fileHash = sha256.convert(encrypted).toString();
      } catch (e) {
        print('\n❌ Error writing snapshot: $e');
        if (finalFile.existsSync()) await finalFile.delete();
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
        parentId: parentId,
      );

      final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);

      if (amend) {
        final newLogs = List<SnapshotLogEntry>.from(trackData.logs);
        newLogs[0] = entry;
        updatedTracks[targetTrackName] = TrackState(
          logs: newLogs,
          originSnapshotId: trackData.originSnapshotId,
          originTrackName: trackData.originTrackName,
        );
      } else {
        updatedTracks[targetTrackName] = TrackState(
          logs: [entry, ...trackData.logs],
          originSnapshotId: trackData.originSnapshotId,
          originTrackName: trackData.originTrackName,
        );
      }

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        tracks: updatedTracks,
      );

      final metaFileToWrite = File(p.join(context.remoteRepoDir.path, 'meta.json'));
      if (metaFileToWrite.existsSync()) {
        await metaFileToWrite.copy(p.join(context.remoteRepoDir.path, 'meta.json.bak'));
      }

      await _atomicWriteString(
          metaFileToWrite, const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()));

      print('🧠 Indexing snapshot files...');
      try {
        await IndexService.saveSnapshotIndex(
          remoteRepoDir: context.remoteRepoDir,
          snapshotId: snapshotId,
          fileMap: currentFingerprint,
        );
      } catch (e) {
        print('⚠️ Warning: Metadata index could not be saved: $e');
      }

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

      final tempsize  = await temp.length();
      if (tempsize > 0) {
        if (await file.exists()) {
          final oldSize = await file.length();
          if (tempsize < oldSize * 0.5 && oldSize > 1024) {
            print('⚠ ${"Warning: New metadata is 50% smaller than previous. Possible data loss?".yellow}');
          }
        }
      }

      try {
        await temp.rename(file.path);
      } catch (_) {
        await temp.copy(file.path);
        await temp.delete();
      }

    } catch (e) {
      print('❌ ${"Critical Error saving metadata:".red} $e');
    }
  }

  Future<void> showAncestry({String? track}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final targetTrack = track ?? context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[targetTrack];

    if (trackData == null || trackData.logs.isEmpty) {
      print('ℹ️ No history found for track "$targetTrack".');
      return;
    }

    print('\n${"--- Lineage & Ancestry ---".cyan.bold}');
    print('${"Track:".padRight(12)} ${targetTrack.yellow}');
    print('${"---".grey}');

    final allSnapshots = <String, SnapshotLogEntry>{};
    for (var t in context.remoteMeta.tracks.values) {
      for (var log in t.logs) {
        allSnapshots[log.id] = log;
      }
    }

    String? currentId = trackData.logs.first.id;
    int depth = 0;

    while (currentId != null) {
      final entry = allSnapshots[currentId];
      
      if (entry == null) {
        print('  ${"⋮".grey} [Missing Link: $currentId]');
        break;
      }

      if (depth == 0) {
        print('  ${"●".green} ${"HEAD".green.bold} ${entry.id.magenta} | ${entry.message.white.bold}');
      } else {
        print('  ${"○".yellow}      ${entry.id.magenta} | ${entry.message}');
      }

      print('         ${entry.createdAt.grey} by ${entry.author ?? "Unknown"}');

      currentId = entry.parentId;
      depth++;

      if (currentId != null) {
        print('  ${"│".grey}');
        print('  ${"↓".grey}');
      } else {
        print('  ${"┴".cyan}');
        print('  ${"ROOT".cyan.bold}');
      }

      if (depth > 1000) {
        print('  ${"⚠".red} Max depth reached.');
        break;
      }
    }

    print('\n${"--- End of Lineage ---".cyan.bold}');

    print('\n${" Legend:".bold}');
    print(' ${"● HEAD".green} : Current point in the track.');
    print(' ${"○".yellow}      : Previous snapshot in time.');
    print(' ${"│ ↓".grey}    : Lineage connection (Parent → Child).');
    print(' ${"┴ ROOT".cyan} : Origin of the track history.');
    print(' ${"ID".magenta}      : Unique snapshot identifier.');
    print('');
  }

  static final RegExp _tableRegex = RegExp(r'((?:^[ \t]*\|.*\|[ \t]*(?:\n|$))+)');
  static final RegExp _tableDividerRegex = RegExp(r'^[ \t]*\|?[\s\-:|]+\|?[ \t]*$');
  
  static final RegExp _jsonKeyRegExp = RegExp(r'("([^"\\]|\\.)*")\s*:');
  static final RegExp _jsonValueRegExp = RegExp(r':\s*("([^"\\]|\\.)*")');
  static final RegExp _jsonLiteralRegExp = RegExp(r'\b(true|false|null|-?\d+(\.\d+)?)\b');
  
  static final RegExp _htmlCommentRegExp = RegExp(r'(<!--.*?-->)');
  static final RegExp _htmlTagRegExp = RegExp(r'(<\/?[a-zA-Z0-9:-]+)');
  static final RegExp _htmlAttrRegExp = RegExp(r'(\s[a-zA-Z0-9:-]+=)');
  static final RegExp _htmlStringRegExp = RegExp(r'("([^"\\]|\\.)*"|' "'" r"([^'\\]|\\.)*')");
  static final RegExp _htmlContentRegExp = RegExp(r'(>[^<]+<)');
  
  static final RegExp _stringLiteralRegExp = RegExp(r'("([^"\\]|\\.)*"|' "'" r"([^'\\]|\\.)*')");
  static final RegExp _pathRegExp = RegExp(r'(?<!:)(\.?\/[\w\d\/\.\-_]+)');
  static final RegExp _badgeRegExp = RegExp(r'\[\[\s?!?(?:(\w+):)?\s?([^\]]+)\s?\]\]');
  static final RegExp _admonitionRegExp = RegExp(r'> \[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]', caseSensitive: false);

  static const Map<String, Set<String>> _langKeywordsMap = {
    'python': {'def', 'if', 'else', 'elif', 'for', 'while', 'return', 'in', 'not', 'and', 'or', 'import', 'from', 'class', 'try', 'except', 'pass', 'print', 'enumerate', 'True', 'False'},
    'dart': {'void', 'main', 'var', 'final', 'const', 'import', 'class', 'extends', 'with', 'implements', 'if', 'else', 'for', 'while', 'return', 'int', 'double', 'String', 'bool', 'List', 'Map', 'Set', 'true', 'false', 'print', 'async', 'await', 'Future', 'this', 'new', 'get', 'set'},
    'javascript': {'function', 'let', 'const', 'var', 'if', 'else', 'for', 'while', 'return', 'import', 'from', 'export', 'default', 'class', 'extends', 'true', 'false', 'console', 'log', 'async', 'await', 'Promise', 'this', 'null', 'typeof'},
    'typescript': {'function', 'let', 'const', 'var', 'if', 'else', 'for', 'while', 'return', 'import', 'from', 'export', 'class', 'interface', 'type', 'string', 'number', 'boolean', 'any', 'void', 'unknown', 'true', 'false', 'console', 'log', 'async', 'await'},
    'go': {'func', 'package', 'import', 'var', 'const', 'type', 'struct', 'interface', 'if', 'else', 'for', 'range', 'return', 'nil', 'true', 'false', 'string', 'int', 'bool', 'error', 'make', 'append', 'len', 'fmt', 'Println', 'Printf'},
    'rust': {'fn', 'let', 'mut', 'struct', 'enum', 'impl', 'trait', 'use', 'mod', 'pub', 'if', 'else', 'match', 'for', 'in', 'while', 'loop', 'return', 'true', 'false', 'String', 'str', 'u32', 'i32', 'bool', 'Option', 'Result', 'Some', 'None', 'Ok', 'Err', 'println'},
    'cpp': {'int', 'float', 'double', 'char', 'bool', 'void', 'class', 'struct', 'public', 'private', 'protected', 'if', 'else', 'for', 'while', 'do', 'return', 'switch', 'case', 'default', 'include', 'define', 'std', 'cout', 'cin', 'endl', 'true', 'false', 'new', 'delete'},
    'json': {'true', 'false', 'null'},
    'bash': {'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'in', 'do', 'done', 'case', 'esac', 'function', 'return', 'exit', 'echo', 'printf', 'local', 'export', 'alias', 'true', 'false', 'sudo', 'cd', 'ls'},
    'powershell': {'if', 'else', 'elseif', 'for', 'foreach', 'while', 'do', 'until', 'return', 'exit', 'function', 'param', 'process', 'try', 'catch', 'finally', 'true', 'false', 'Write-Host', 'Write-Output', 'Get-ChildItem', 'Set-ExecutionPolicy', 'Bypass', 'Invoke-WebRequest', '-Uri'},      
    'terminal': {
      'sudo', 'cd', 'ls', 'dir', 'mkdir', 'rm', 'rmdir', 'cp', 'mv', 'cat', 'echo', 'clear', 'cls',
      'git', 'ssh', 'curl', 'wget', 'ping', 'ipconfig', 'ifconfig', 'chmod', 'chown', 'ps', 'kill',
      'npm', 'node', 'deno', 'bun', 'pip', 'python', 'python3', 'go', 'rustc', 'cargo', 'dart', 'flutter', 'vcs',
      'Date:', 'Author:', 'Message:', 'Commit:', 'History:', 'Track:', 'Branch:', 'Status:', 'Version:', 'Changes:',
      'LOGIC:', 'TESTS:', 'DOCS:', 'ASSETS:', 'CONFIG:', 'OTHER:', 'Snapshot', 'history',
      '(latest)', 'latest', 'master', 'main', 'stable', 'release',
      'error', 'ERROR', 'warning', 'WARNING', 'success', 'SUCCESS', 'info', 'INFO', 'failed', 'FAILED',
      'done', 'DONE', 'compiled', 'building', 'running', 'exit', 'OK', 'FAIL',
      '--help', '-h', '--version', '-v', '--force', '-f', '--all', '-a', '--verbose', '--graph', '--list', '-l', '--ext', '--full'
    }
  };

  String _convertNodesToAnsi(List<Node> nodes) {
    final sb = StringBuffer();
    
    void traverse(Node node) {
      if (node.value != null) {
        final className = node.className?.toLowerCase().trim() ?? '';

        switch (className) {
          case 'keyword':
          case 'built_in':
          case 'type':
          case 'literal':
          case 'operator':
            sb.write(node.value!.magenta.bold);
            break;

          case 'string':
          case 'quote':
          case 'subst':
            sb.write(node.value!.green);
            break;

          case 'number':
          case 'symbol':
          case 'bullet':
          case 'regexp':
          case 'variable':
          case 'template-variable':
            sb.write(node.value!.yellow);
            break;

          case 'comment':
            sb.write(node.value!.grey.italic);
            break;

          case 'title':
          case 'class':
          case 'function':
          case 'title.function':
          case 'title.class':
          case 'title function':
          case 'title class':
            sb.write(node.value!.cyan);
            break;

          case 'params':
          case 'attr':
          case 'property':
          case 'attribute':
            sb.write(node.value!.white);
            break;

          case 'meta':
          case 'meta-keyword':
          case 'meta keyword':
            sb.write(node.value!.blue);
            break;

          default:
            sb.write(node.value!);
        }
      }
      
      if (node.children != null) {
        for (var child in node.children!) {
          traverse(child);
        }
      }
    }

    for (var node in nodes) {
      traverse(node);
    }
    return sb.toString();
  }

  bool _languagesRegistered = false;

  String _renderTableMatch(Match tableMatch) {
    List<String> rows = tableMatch.group(0)!.trim().split('\n');
    List<List<String>> data = rows
        .where((r) => !_tableDividerRegex.hasMatch(r))
        .map((r) {
          String rowContent = r.trim();
          if (rowContent.startsWith('|')) rowContent = rowContent.substring(1);
          if (rowContent.endsWith('|')) rowContent = rowContent.substring(0, rowContent.length - 1);
          return rowContent.split('|').map((c) => c.trim()).toList();
        }).toList();

    if (data.isEmpty) return "";

    int cols = data.map((e) => e.length).reduce((a, b) => a > b ? a : b);
    List<int> widths = List.filled(cols, 0);
    
    List<List<AnsiString>> renderedData = data.map((row) {
      return List.generate(cols, (i) {
        String content = (i < row.length) ? row[i] : "";
        content = _applyInlineFormatting(content);
        var cell = AnsiString(content);
        if (cell.visualLength > widths[i]) widths[i] = cell.visualLength;
        return cell;
      });
    }).toList();

    String tableOut = "\n";
    for (var i = 0; i < renderedData.length; i++) {
      String line = "  ┃ ".cyan; 
      for (var j = 0; j < cols; j++) {
        line += renderedData[i][j].padRight(widths[j]) + (j == cols - 1 ? " ┃".cyan : " │ ".grey);
      }
      tableOut += (i == 0) ? line.bold + "\n" : line + "\n";
      if (i == 0) {
        tableOut += "  ┣━".cyan + widths.map((w) => "━" * w).join("━┿━".cyan) + "━┫".cyan + "\n";
      }
    }
    return tableOut;
  }

  String _highlightCodeBlock(String content, String lang) {
    if (lang.isEmpty) return content;

    final keywords = _langKeywordsMap[lang];
    if (keywords == null) {
      if (lang == 'html' || lang == 'xml') {
        final lines = content.split('\n');
        final fallbackLines = <String>[];
        for (var l in lines) {
          String processedLine = l;
          processedLine = processedLine.replaceAllMapped(_htmlCommentRegExp, (m) => m.group(0)!.grey.italic);
          processedLine = processedLine.replaceAllMapped(_htmlTagRegExp, (m) => m.group(0)!.magenta.bold);
          processedLine = processedLine.replaceAllMapped(_htmlAttrRegExp, (m) => m.group(0)!.cyan);
          processedLine = processedLine.replaceAllMapped(_htmlStringRegExp, (m) => m.group(0)!.green);
          processedLine = processedLine.replaceAllMapped(_htmlContentRegExp, (m) => ">${m.group(0)!.substring(1, m.group(0)!.length - 1).white}<");
          fallbackLines.add(processedLine);
        }
        return fallbackLines.join('\n');
      }

      try {
        final result = highlight.parse(content, language: lang);
        return _convertNodesToAnsi(result.nodes ?? []);
      } catch (e) {
        return content;
      }
    }

    final lines = content.split('\n');
    final fallbackLines = <String>[];
    
    final keywordPattern = RegExp('\\b(${keywords.map(RegExp.escape).join('|')})\\b');

    for (var l in lines) {
      String trimmedL = l.trim();
      
      if (lang == 'python' && trimmedL.startsWith('#')) {
        fallbackLines.add(l.grey.italic);
        continue;
      }
      if (const {'dart', 'javascript', 'typescript', 'go', 'rust', 'cpp'}.contains(lang) && trimmedL.startsWith('//')) {
        fallbackLines.add(l.grey.italic);
        continue;
      }
      
      String processedLine = l;
      
      if (lang == 'json') {
        processedLine = processedLine.replaceAllMapped(_jsonKeyRegExp, (m) => "${m.group(1)!.cyan}:");
        processedLine = processedLine.replaceAllMapped(_jsonValueRegExp, (m) => ": ${m.group(1)!.green}");
        processedLine = processedLine.replaceAllMapped(_jsonLiteralRegExp, (m) => m.group(0)!.yellow);
      } 
      else if (lang == 'terminal' || lang == 'shell') {
        final Set<String> terminalKeywords = {
          ..._langKeywordsMap['terminal']!,
          ..._langKeywordsMap['bash']!,
          ..._langKeywordsMap['powershell']!,
        };

        final List<String> words = l.split(RegExp(r'\s+'));
        final Set<String> uniqueWords = {};
        
        for (var rawWord in words) {
          String cleanWord = rawWord.replaceAll(RegExp(r'^[═*│├──└──\s]+'), '').trim();
          if (terminalKeywords.contains(cleanWord)) {
            uniqueWords.add(cleanWord);
          }
        }
        
        for (var word in uniqueWords) {
          String escapedWord = RegExp.escape(word);
          processedLine = processedLine.replaceAllMapped(
            RegExp('(?<=^|\\s|[═*│├──└──])$escapedWord(?=\\s|\$|\\b)'), 
            (match) {
              if (word.endsWith(':') || word == 'Snapshot' || word == 'history') {
                return word.yellow.bold;
              } else if (word.startsWith('-')) {
                return word.cyan;
              } else if (const {'error', 'ERROR', 'failed', 'FAILED', 'FAIL'}.contains(word)) {
                return word.red.bold;
              } else if (const {'success', 'SUCCESS', 'done', 'DONE', 'OK'}.contains(word)) {
                return word.green.bold;
              } else if (word == 'warning' || word == 'WARNING') {
                return word.yellow;
              }
              return word.magenta.bold; 
            }
          );
        }
      }
      else {
        processedLine = processedLine.replaceAllMapped(keywordPattern, (m) {
          final word = m.group(0)!;
          if (const {'print', 'enumerate', 'console', 'log', 'Println', 'Printf', 'println', 'cout', 'Write-Host', 'Write-Output'}.contains(word)) {
            return word.cyan;
          }
          return word.magenta.bold;
        });
        
        processedLine = processedLine.replaceAllMapped(_stringLiteralRegExp, (m) => m.group(0)!.green);
      }
      
      fallbackLines.add(processedLine);
    }
    
    return fallbackLines.join('\n');
  }

  String _renderMarkdown(String text) {
    if (text.isEmpty) return text;

    if (!_languagesRegistered) {
      allLanguages.forEach((name, engine) {
        highlight.registerLanguage(name, engine);
        highlight.registerLanguage(name.toLowerCase(), engine);
      });
      _languagesRegistered = true;
    }

    String rendered = text.replaceAll('\u00A0', ' ').replaceAll('\r\n', '\n');

    rendered = rendered.replaceAllMapped(_tableRegex, _renderTableMatch);

    List<String> rawLines = rendered.split('\n');
    List<String> preProcessedLines = [];
    bool inCodeBlock = false;
    String currentLang = "";
    List<String> codeBlockContent = [];

    for (var line in rawLines) {
      String trimmedLine = line.trim();
      
      if (trimmedLine.startsWith('```')) {
        if (!inCodeBlock) {
          inCodeBlock = true;
          String afterBackticks = trimmedLine.substring(3).trim();
          currentLang = afterBackticks.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '').toLowerCase();
          codeBlockContent.clear();
          continue;
        } else {
          inCodeBlock = false;
          String fullContent = codeBlockContent.join('\n');
          String highlighted = _highlightCodeBlock(fullContent, currentLang);
          
          preProcessedLines.addAll(highlighted.split('\n').map((l) => '    │ '.grey + l));
          continue;
        }
      }

      if (inCodeBlock) {
        codeBlockContent.add(line);
      } else {
        preProcessedLines.add(line);
      }
    }

    List<String> result = [];
    String? activeAdmonition;

    for (var line in preProcessedLines) {
      String trimmed = line.trim();

      if (line.contains('┃') || line.contains('┣') || line.contains('│')) {
        result.add(line);
        continue;
      }

      final indentMatch = RegExp(r'^[ \t]*').firstMatch(line);
      final String indent = indentMatch != null ? indentMatch.group(0)! : '';

      if (trimmed.startsWith('> [!')) {
        final match = _admonitionRegExp.firstMatch(trimmed);
        if (match != null) {
          activeAdmonition = match.group(1)!.toUpperCase();
          final icons = {'NOTE': 'ℹ', 'TIP': '💡', 'IMPORTANT': '📢', 'WARNING': '⚠️', 'CAUTION': '🛑'};
          final head = ' ${icons[activeAdmonition]} $activeAdmonition';
          final styles = {
            'IMPORTANT': head.bold.cyan, 'WARNING': head.bold.yellow,
            'CAUTION': head.bold.red, 'TIP': head.bold.green, 'NOTE': head.bold.blue,
          };
          result.add(indent + (styles[activeAdmonition] ?? head.bold.blue));
          continue;
        }
      }

      if (trimmed.startsWith('>')) {
        String content = trimmed.replaceFirst('>', '').trimLeft();
        if (content.isNotEmpty) {
          String colorCode = activeAdmonition == 'IMPORTANT' ? "\x1B[36m" : 
                            (activeAdmonition == 'WARNING' ? "\x1B[33m" : 
                            (activeAdmonition == 'TIP' ? "\x1B[32m" : "\x1B[34m"));
          
          content = _applyInlineFormatting(content, colorCode);
          if (activeAdmonition == 'IMPORTANT') result.add(indent + '  ┃ '.cyan + content.cyan);
          else if (activeAdmonition == 'WARNING' || activeAdmonition == 'CAUTION') result.add(indent + '  ┃ '.yellow + content.yellow);
          else if (activeAdmonition == 'TIP') result.add(indent + '  ┃ '.green + content.green);
          else result.add(indent + '  ┃ '.grey + content.grey.italic);
        }
        continue;
      }

      if (trimmed.isNotEmpty) activeAdmonition = null;

      String processed = line;
      
      if (trimmed.startsWith('# ')) {
        processed = '\n' + indent + '▌ '.cyan.bold + _applyInlineFormatting(trimmed.replaceFirst('# ', ''), "\x1B[36m\x1B[1m").bold.cyan.underline + '\n';
      } 
      else if (trimmed.startsWith('## ')) {
        processed = '\n' + indent + _applyInlineFormatting(trimmed.replaceFirst('## ', ''), "\x1B[1m").bold + '\n' + indent + ('─' * 30).grey;
      }
      else if (trimmed.startsWith('### ')) {
        processed = '\n' + indent + '📁 '.yellow + _applyInlineFormatting(trimmed.replaceFirst('### ', ''), "\x1B[33m").bold.yellow;
      }
      else if (trimmed.startsWith('#### ')) {
        processed = indent + '└ '.grey + _applyInlineFormatting(trimmed.replaceFirst('#### ', ''), "\x1B[3;90m").grey;
      } 
      else if (RegExp(r'^[•\-\*] ').hasMatch(trimmed)) {
        processed = indent + '• '.cyan + _applyInlineFormatting(trimmed.substring(2));
      }
      else if (trimmed == '---' || trimmed == '***' || trimmed == '___') {
        processed = '\n' + indent + ('┈' * 40).grey + '\n';
      } else {
        processed = _applyInlineFormatting(processed);
      }
      result.add(processed);
    }
    return result.join('\n');
  }

  String _applyInlineFormatting(String text, [String? contextColor]) {
    String res = text;
    final restore = contextColor ?? "\x1B[0m";

    res = res.replaceAllMapped(_pathRegExp, (m) => m.group(1)!.white.italic + restore);
    res = res.replaceAllMapped(RegExp(r'\[\s?([A-Z0-9_-]{3,})\s?\]'), (m) => '[ '.grey + m.group(1)!.white.bold + ' ]'.grey + restore);
    res = res.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!.green + restore);
    res = res.replaceAllMapped(RegExp(r'\*\*(.*?)\*\*'), (m) => m.group(1)!.bold + restore);
    res = res.replaceAllMapped(RegExp(r'(https?:\/\/[^\s]+)'), (m) => m.group(1)!.blue.underline + restore);

    return _renderBadges(res, contextColor);
  }

  String _renderBadges(String text, [String? contextColor]) {
    return text.splitMapJoin(
      _badgeRegExp,
      onMatch: (Match m) {
        final key = (m.group(1) ?? 'CYAN').toUpperCase();
        final label = (m.group(2) ?? "").trim();
        String icon = _getIconForBadge(key);
        final badgeText = ' $icon$label '.bold;
        final theme = _getBadgeTheme(key, badgeText);
        String resetAndRestore = (contextColor != null) ? "\x1B[0m$contextColor" : "\x1B[0m";
        return theme[0].replaceAll(badgeText, theme[1]) + resetAndRestore;
      },
      onNonMatch: (String nonMatch) => nonMatch,
    );
  }

  String _getIconForBadge(String key) {
    if (const {'RED', 'CRITICAL', 'CAUTION'}.contains(key)) return "✘ ";
    if (const {'GREEN', 'SUCCESS', 'TIP'}.contains(key)) return "✔ ";
    if (const {'YELLOW', 'WARNING'}.contains(key)) return "⚠️ ";
    if (const {'MAGENTA', 'TAG'}.contains(key)) return "🏷️ ";
    if (const {'BLUE', 'INFO', 'NOTE'}.contains(key)) return "ℹ️ ";
    if (const {'CYAN', 'SYSTEM'}.contains(key)) return "⚙️ ";
    return "";
  }

  List<String> _getBadgeTheme(String key, String text) {
    final Map<String, List<String>> themes = {
      'RED': [text.onRed, text.white],
      'CRITICAL': [text.onRed, text.white],
      'CAUTION': [text.onRed, text.white],
      'GREEN': [text.onGreen, text.black],
      'SUCCESS': [text.onGreen, text.black],
      'TIP': [text.onGreen, text.black],
      'YELLOW': [text.onYellow, text.black],
      'WARNING': [text.onYellow, text.black],
      'BLUE': [text.onBlue, text.white],
      'INFO': [text.onBlue, text.white],
      'NOTE': [text.onBlue, text.white],
      'MAGENTA': [text.onMagenta, text.white],
      'TAG': [text.onMagenta, text.white],
      'WHITE': [text.onWhite, text.black],
      'CYAN': [text.onCyan, text.black],
      'SYSTEM': [text.onCyan, text.black],
    };
    return themes[key] ?? [text.onCyan, text.black];
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

      if (entry.changeSummary.isEmpty) {
        print('$subPrefix     ${"Changes:".yellow.padRight(10)} ${"(none)".red}');
      } else {
        print(
          '$subPrefix     ${"Changes:".yellow.padRight(10)} '
          '${counts.total.toString().green} file(s) '
          '(${'+${counts.added}'.green} ${'~${counts.modified}'.yellow} ${'-${counts.deleted}'.red})',
        );

        _printGroupedSummary(entry.changeSummary, subPrefix);

        switch (mode) {
          case LogViewMode.summary:
            break;

          case LogViewMode.standard:
            final preview = entry.changeSummary.take(5).toList();
            for (final c in preview) {
              if (c.startsWith('[N]')) print('$subPrefix       ${c.green}');
              else if (c.startsWith('[M]')) print('$subPrefix       ${c.yellow}');
              else if (c.startsWith('[D]')) print('$subPrefix       ${c.red}');
              else print('$subPrefix       $c');
            }
            final remaining = entry.changeSummary.length - preview.length;
            if (remaining > 0) {
              print('$subPrefix       ${"... and $remaining more change(s)".yellow}');
            }
            break;

          case LogViewMode.full:
            for (final c in entry.changeSummary) {
              if (c.startsWith('[N]')) print('$subPrefix       ${c.green}');
              else if (c.startsWith('[M]')) print('$subPrefix       ${c.yellow}');
              else if (c.startsWith('[D]')) print('$subPrefix       ${c.red}');
              else print('$subPrefix       $c');
            }
            break;
        }
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

  void _printGroupedSummary(List<String> changes, String subPrefix) {
    var logic = 0, tests = 0, assets = 0, config = 0, docs = 0, other = 0;

    for (final change in changes) {
      final cleanPath = change.length > 4 ? change.substring(4).trim() : change;
      final ext = p.extension(cleanPath).toLowerCase();
      final fileName = p.basename(cleanPath).toLowerCase();
      final pathSegments = p.split(cleanPath).map((s) => s.toLowerCase()).toList();

      if (fileName.contains('_test.') || fileName.contains('.spec.') || pathSegments.contains('test') || pathSegments.contains('test_driver')) {
        tests++;
      } else if (['.dart', '.js', '.py', '.cpp', '.h', '.ts', '.go', '.rs', '.php', '.c', '.java', '.kt', '.swift', '.cs'].contains(ext)) {
        logic++;
      } else if (['.png', '.jpg', '.jpeg', '.svg', '.gif', '.webp', '.ico', '.mp4', '.wav', '.mp3', '.ttf', '.otf', '.woff', '.woff2'].contains(ext)) {
        assets++;
      } else if (['.yaml', '.json', '.xml', '.toml', '.lock', '.gradle', '.plist', '.properties', '.conf', '.ini', '.env'].contains(ext) || fileName == 'dockerfile' || fileName == 'makefile') {
        config++;
      } else if (['.md', '.adoc', '.rst', '.txt'].contains(ext) || fileName == 'license' || fileName == 'changelog' || fileName == 'readme') {
        docs++;
      } else {
        other++;
      }
    }

    final List<String> treeLines = [];
    if (logic > 0) treeLines.add('🛠️  LOGIC: $logic file(s)');
    if (tests > 0) treeLines.add('🧪  TESTS: $tests file(s)');
    if (assets > 0) treeLines.add('🎨  ASSETS: $assets file(s)');
    if (config > 0) treeLines.add('⚙️  CONFIG: $config file(s)');
    if (docs > 0) treeLines.add('ℹ️  DOCS: $docs file(s)');
    if (other > 0) treeLines.add('📄  OTHER: $other file(s)');

    for (var k = 0; k < treeLines.length; k++) {
      final isLastTreeLine = k == treeLines.length - 1;
      final branch = isLastTreeLine ? '└── ' : '├── ';
      print('$subPrefix      ${branch.grey}${treeLines[k].grey}');
    }
  }

  ChangeCounts countChanges(List<String> changes) {
    var added = 0;
    var modified = 0;
    var deleted = 0;

    for (final c in changes) {
      if (c.startsWith('[N]')) added++;
      else if (c.startsWith('[M]')) modified++;
      else if (c.startsWith('[D]')) deleted++;
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
    bool deep = false,
  }) async {
    final context = await loadRepoContext();
    if (context == null) return;

    if (deep && snapshotId == null) {
      snapshotId = context.remoteMeta.tracks[context.remoteMeta.activeTrack]?.logs.firstOrNull?.id;
      if (snapshotId == null) {
        print('❌ No snapshots found to perform deep verification.');
        return;
      }
    }

    if (verifyAll) {
      final password = askPassword();
      if (password == null) return;
      await _verifyAllSnapshots(context, password);
      return;
    }

    if (snapshotId == null || snapshotId.trim().isEmpty) {
      print('❌ ${"Usage: vcs verify <snapshot_id> [--all] [--deep]".red}');
      return;
    }

    if (deep) {
      await _verifyDeep(context, snapshotId);
    } else {
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
        print('✅ ${"Snapshot $snapshotId is valid and decryptable.".green}');
      } catch (e) {
        print('❌ ${"Snapshot verification failed:".red} $e');
      }
    }
  }

  Future<void> _verifyDeep(RepoContext context, String id) async {
    final indexPath = p.normalize(
      p.join(context.remoteRepoDir.path, 'index', '$id.json')
    );
    
    final indexFile = File(indexPath);

    if (!indexFile.existsSync()) {
      print('ℹ️  ${"Note:".blue} Snapshot $id was created with a legacy version (no delta-index).');
      print('    Looked in: ${indexFile.path.grey}');
      return;
    }

    print('\n🔍 ${"Deep Verification:".cyan} Comparing live files against index ${id.yellow}');
    print('─' * 60);

    try {
      final content = await indexFile.readAsString();
      final indexData = jsonDecode(content);
      
      final Map<String, dynamic>? fingerprint = indexData['file_map'];

      if (fingerprint == null || fingerprint.isEmpty) {
        print('⚠️  ${"Index found but file_map is empty.".yellow}');
        return;
      }

      int ok = 0;
      int modified = 0;
      int missing = 0;

      for (var entry in fingerprint.entries) {
        final relativePath = entry.key;
        final expectedHash = entry.value.toString();
        
        final localFile = File(p.normalize(p.join(Directory.current.path, relativePath)));

        if (!localFile.existsSync()) {
          print('  ${"Missing:".red} $relativePath');
          missing++;
          continue;
        }

        final currentHash = (await sha256.bind(localFile.openRead()).first).toString();

        if (currentHash == expectedHash) {
          ok++;
        } else {
          modified++;
          print('  ${"Modified:".yellow} $relativePath');
        }
      }

      print('─' * 60);
      print('📊 ${"Deep Scan Result:".bold} $ok OK | $modified Modified | $missing Missing');

      if (modified == 0 && missing == 0) {
        print('\n✨ ${"Local files match the snapshot perfectly.".green.bold}');
      } else {
        print('\n⚠️ ${"Discrepancies found between disk and snapshot.".yellow}');
      }
    } catch (e) {
      print('❌ ${"Error during deep verification:".red} $e');
    }
  }

  Future<void> _verifyAllSnapshots(
    RepoContext context,
    String password,
  ) async {
    final allLogs = context.remoteMeta.tracks.values.expand((t) => t.logs).toList();
    final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
    final indexDir = Directory(p.join(context.remoteRepoDir.path, 'index'));

    print('\n🔍 ${"Verifying ${allLogs.length} snapshots...".cyan}');
    print('═' * 60);

    int valid = 0;
    int failed = 0;
    int legacy = 0;

    final expectedFiles = <String>{};

    for (final entry in allLogs) {
      expectedFiles.add(entry.fileName);
      
      final indexFile = File(p.normalize(p.join(indexDir.path, '${entry.id}.json')));

      if (indexFile.existsSync()) {
      } else {
        legacy++;
      }

      final vcsFile = File(p.normalize(p.join(snapshotsDir.path, entry.fileName)));

      if (!vcsFile.existsSync()) {
        failed++;
        print('${"[MISSING]".red} ${entry.id.yellow}');
        continue;
      }

      try {
        final snapshot = await readSnapshot(context, entry.id, password: password);
        if (snapshot == null) throw 'Decryption failed';
        
        ZipDecoder().decodeBytes(snapshot.zipBytes, verify: true);

        valid++;
        final suffix = indexFile.existsSync() ? "" : " (Legacy)".grey;
        print('${"[OK]".green} ${entry.id.green}$suffix');
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
          if (!expectedFiles.contains(name) && !name.startsWith('.tmp_') && name != 'vcs_aliases.json') {
            orphanFiles.add('snapshots/$name');
          }
        }
      }
    }
    
    if (indexDir.existsSync()) {
      final allLogIds = allLogs.map((l) => l.id).toSet();
      for (final entity in indexDir.listSync()) {
        if (entity is File) {
          final id = p.basenameWithoutExtension(entity.path);
          if (!allLogIds.contains(id)) {
            orphanFiles.add('index/${p.basename(entity.path)}');
          }
        }
      }
    }

    print('═' * 60);
    print('${"Snapshots checked:".yellow.padRight(20)} ${allLogs.length}');
    print('${"Valid:".green.padRight(20)} $valid');
    if (legacy > 0) print('${"Legacy (no index):".blue.padRight(20)} $legacy');
    print('${"Failed:".red.padRight(20)} $failed');
    print('${"Orphan files:".yellow.padRight(20)} ${orphanFiles.length}');

    if (orphanFiles.isNotEmpty) {
      print('\n🗂️ ${"Orphan files found:".yellow}');
      for (final orphan in orphanFiles) {
        print('  ${orphan.yellow}');
      }
    }

    if (failed == 0) {
      print('\n✅ ${"Repository verification complete.".green}');
    } else {
      print('\n⚠️ ${"Repository verification completed with errors.".yellow}');
    }
  }

  Future<void> doctor({bool rebuildMode = false, bool reindexMode = false}) async {
    final reporter = DoctorReporter();
    reporter.log('# 🛠️ VCS Diagnostic Report\n*Generated on: ${DateTime.now().toLocal()}*\n');

    print('\n🔬 ${"Repository diagnostics".cyan}');
    print('═' * 60);

    final snapshotsLackingIndex = <String>[];
    var okCount = 0;
    var warnCount = 0;

    String stripAnsi(String input) {
      return input.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');
    }

    void check(bool ok, String label, {String? details, bool isInfo = false}) {
      final cleanLabel = stripAnsi(label);
      final cleanDetails = details != null ? stripAnsi(details) : null;

      if (ok) {
        okCount++;
        print('  ${"✔".green} ${label.green}');
        reporter.log('- ✅ **$cleanLabel**');
      } else if (isInfo) {
        print('  ${"ℹ".blue} ${label.blue}');
        reporter.log('- ℹ️ **$cleanLabel**');
      } else {
        warnCount++;
        print('  ${"⚠️".yellow} ${label.yellow}');
        reporter.log('- ⚠️ **$cleanLabel**');
      }

      if (cleanDetails != null && cleanDetails.isNotEmpty) {
        print('      $details');
        reporter.log('    > *$cleanDetails*');
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
      
      final markerFile = File(p.normalize(p.join(usb.path, driveMarkerFile)));
      try {
        final lines = await markerFile.readAsLines();
        final markerMap = Map.fromEntries(
          lines.where((l) => l.contains('=')).map((l) => MapEntry(l.split('=')[0], l.split('=')[1]))
        );
        final provisionedBy = markerMap['provisionedBy'];
        final provisionedAt = markerMap['provisionedAt'];

        if (provisionedBy != null && provisionedAt != null) {
          check(true, 'VCS Marker valid', details: 'Linked to host: ${provisionedBy.cyan} (at $provisionedAt)');
        } else {
          check(false, 'Legacy Marker detected', isInfo: true, details: 'This drive is v0.1. Run "vcs setup" to upgrade metadata.');
        }
      } catch (e) {
        check(false, 'VCS Marker readable', details: 'Marker file is corrupt or unreadable.');
      }

      final reposDirPath = p.normalize(p.join(usb.path, remoteReposDir));
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
        final context = await loadRepoContext();
        if (context == null) {
          check(false, 'Repository Context', details: 'Could not load local or remote repository context.');
          return;
        }

        final localMetaRaw = jsonDecode(await _localRepoFile.readAsString());
        final repoId = localMetaRaw['repo_id']?.toString() ?? '';
        final remoteRepoDir = Directory(p.normalize(p.join(usb.path, remoteReposDir, repoId)));

        if (!remoteRepoDir.existsSync()) {
          check(false, 'Remote repository binding', details: 'Repo ID "$repoId" not found on this drive.');
        } else {
          final metaFile = File(p.normalize(p.join(remoteRepoDir.path, remoteMetaFileName)));
          final backupFile = File('${metaFile.path}.bak');
          final snapshotsDir = Directory(p.normalize(p.join(remoteRepoDir.path, 'snapshots')));
          final indexDir = Directory(p.normalize(p.join(remoteRepoDir.path, 'index')));
          
          RepoMeta? meta;
          bool restoredFromBackup = false;
          bool rebuildSuccess = false;

          if (!metaFile.existsSync() || rebuildMode) {
            if (rebuildMode && snapshotsDir.existsSync()) {
              print('  ${"🔧".magenta} Recovery Mode: Executing physical parser scanner...');
              final files = snapshotsDir.listSync().whereType<File>().where((f) => f.path.endsWith('.vcs'));
              Map<String, List<SnapshotLogEntry>> recoveredTracks = {};

              for (var file in files) {
                final content = await file.readAsString();
                if (content.contains('---VCS_DATA_START---')) {
                  final headerLine = content.split('\n').first;
                  final trackMatch = RegExp(r'Track: (.*?) \|').firstMatch(headerLine);
                  final parentMatch = RegExp(r'Parent: (.*)').firstMatch(headerLine);
                  final dateMatch = RegExp(r'Date: (.*?) \|').firstMatch(headerLine);
                  final dateStr = dateMatch != null ? dateMatch.group(1)! : DateTime.now().toUtc().toIso8601String();

                  if (trackMatch != null) {
                    final trackName = trackMatch.group(1)!;
                    final parentId = parentMatch?.group(1);
                    final snapshotId = p.basenameWithoutExtension(file.path);

                    final entry = SnapshotLogEntry(
                      id: snapshotId,
                      message: "[Recovered by Doctor]",
                      author: "System",
                      createdAt: dateStr,
                      fileName: p.basename(file.path),
                      hash: (await sha256.bind(file.openRead()).first).toString(),
                      parentId: (parentId == "null" || parentId == null) ? null : parentId,
                      changeSummary: ["[Reconstructed]"],
                    );
                    recoveredTracks.putIfAbsent(trackName, () => []).add(entry);
                  }
                }
              }

              if (recoveredTracks.isNotEmpty) {
                final inferredProjectName = p.basename(remoteRepoDir.path);
                final now = DateTime.now().toUtc().toIso8601String();
                final finalTracks = recoveredTracks.map((name, logs) {
                  logs.sort((a, b) => a.createdAt.compareTo(b.createdAt)); 
                  return MapEntry(name, TrackState(logs: logs, originTrackName: name == 'main' ? null : 'main'));
                });

                meta = RepoMeta(
                  repoId: repoId,
                  projectName: inferredProjectName, 
                  createdAt: now,
                  updatedAt: now,
                  formatVersion: 4,
                  activeTrack: "main",
                  tracks: finalTracks,
                  tags: {},
                );
                await metaFile.writeAsString(const JsonEncoder.withIndent('  ').convert(meta.toJson()), flush: true);
                rebuildSuccess = true;
              }
            } else if (backupFile.existsSync()) {
              print('  ${"🔧".magenta} Main metadata missing. Restoring from backup...');
              meta = RepoMeta.fromJson(jsonDecode(await backupFile.readAsString()));
              await metaFile.writeAsString(jsonEncode(meta), flush: true);
              restoredFromBackup = true;
            }
          } else {
            try {
              meta = RepoMeta.fromJson(jsonDecode(await metaFile.readAsString()));
            } catch (e) {
              if (backupFile.existsSync()) {
                print('  ${"🔧".magenta} Primary metadata corrupt. Rescuing from backup...');
                meta = RepoMeta.fromJson(jsonDecode(await backupFile.readAsString()));
                await metaFile.writeAsString(jsonEncode(meta), flush: true);
                restoredFromBackup = true;
              }
            }
          }

          if (meta == null) {
            check(false, 'Metadata availability', details: 'Critical: Meta, backup and rebuild failed.');
          } else {
            String metaLabel = 'Metadata healthy';
            if (rebuildSuccess) metaLabel = 'Metadata rebuilt from physical files';
            if (restoredFromBackup) metaLabel = 'Metadata restored from backup';
            check(true, metaLabel, details: '${meta.tracks.length} tracks registered.');

            final Map<String, String?> expectedHashes = {};
            final allLogIds = <String>{};
            for (var track in meta.tracks.values) {
              for (var entry in track.logs) {
                expectedHashes[entry.fileName] = entry.hash;
                allLogIds.add(entry.id);
              }
            }

            if (snapshotsDir.existsSync()) {
              final List<File> snapshotsFiles = snapshotsDir.listSync().whereType<File>().toList();
              int corruptCount = 0;
              int verifiedCount = 0;
              snapshotsLackingIndex.clear();

              print('  ${"⚙".cyan} Scanning snapshot blocks hashes...');
              
              for (var file in snapshotsFiles) {
                final name = p.basename(file.path);
                if (name.startsWith('.tmp_') || !name.endsWith('.vcs')) continue;

                if (expectedHashes.containsKey(name)) {
                  final savedHash = expectedHashes[name];
                  if (savedHash != null) {
                    stdout.write('.'.grey); 
                    final currentHash = (await sha256.bind(file.openRead()).first).toString();
                    if (currentHash != savedHash) {
                      corruptCount++;
                      print('\n  ${"❌".red} Integrity fail: ${name.grey} (Hash mismatch)');
                    } else {
                      verifiedCount++;
                    }
                  }
                  
                  final snapshotId = p.basenameWithoutExtension(name);
                  final indexFile = File(p.normalize(p.join(indexDir.path, '$snapshotId.json')));
                  if (!indexFile.existsSync()) {
                    snapshotsLackingIndex.add(snapshotId);
                  }
                }
              }
              if (verifiedCount > 0) stdout.write('\n');

              check(corruptCount == 0, 'Data Content Health', 
                details: corruptCount > 0 ? 'Found $corruptCount corrupt files!' : 'Verified $verifiedCount snapshots securely.');

              if (snapshotsLackingIndex.isNotEmpty) {
                if (reindexMode) {
                  final finalPassword = askPassword();
                  if (finalPassword == null || finalPassword.isEmpty) {
                    print('❌ ${"Reindexing Aborted:".red} Password required.');
                    return;
                  }

                  print('\n  ${"⚡".magenta} Retroactive Parallel Indexing...');
                  const int maxConcurrentTasks = 3;
                  for (var i = 0; i < snapshotsLackingIndex.length; i += maxConcurrentTasks) {
                    final end = (i + maxConcurrentTasks < snapshotsLackingIndex.length) ? i + maxConcurrentTasks : snapshotsLackingIndex.length;
                    final batch = snapshotsLackingIndex.sublist(i, end);

                    await Future.wait(batch.map((snapshotId) async {
                      try {
                        final DecryptedSnapshot? snapshotData = await readSnapshot(context, snapshotId, password: finalPassword);
                        if (snapshotData != null) {
                          await IndexService.saveSnapshotIndex(remoteRepoDir: remoteRepoDir, snapshotId: snapshotId, fileMap: Map<String, String>.from(snapshotData.fingerprint));
                          print('    ${"✔".green} Fast-Diff Index regenerated for: ${snapshotId.cyan}');
                        }
                      } catch (e) {
                        print('    ${"❌".red} Error building index $snapshotId: $e');
                      }
                    }));
                  }
                  check(true, 'Fast-Diff Optimization', details: 'All missing delta indices regenerated.');
                } else {
                  check(false, 'Fast-Diff Optimization', details: '${snapshotsLackingIndex.length} snapshots lack indices. Run "vcs doctor --reindex".');
                }
              } else {
                check(true, 'Fast-Diff Optimization', details: 'All snapshots have valid delta indices.');
              }

              final List<File> indexFiles = indexDir.existsSync() ? indexDir.listSync().whereType<File>().toList() : [];
              final orphans = <String>[];
              for (var f in snapshotsFiles) {
                final name = p.basename(f.path);
                if (name.startsWith('.tmp_') || name == 'vcs_aliases.json') continue;
                if (name.endsWith('.vcs') && !expectedHashes.containsKey(name)) orphans.add('snapshots/$name');
              }
              for (var f in indexFiles) {
                final name = p.basename(f.path);
                final id = p.basenameWithoutExtension(name);
                if (!allLogIds.contains(id)) orphans.add('index/$name');
              }

              if (orphans.isNotEmpty) {
                check(false, 'Storage optimization', details: 'Found ${orphans.length} orphans. Run "vcs prune --garbage".');
              } else {
                check(true, 'Storage optimized', details: 'No orphan files detected.');
              }
            }
          }
        }
      } catch (e) {
        check(false, 'Critical Diagnosis Error', details: e.toString());
      }
    }

    print('\n${"Summary".yellow}');
    print('─' * 60);
    print('  ${"OK:".green} $okCount');
    print('  ${"Warnings/Errors:".red} $warnCount');
    reporter.log('\n---\n### 📊 Summary');
    reporter.log('- ✅ **Total OK:** $okCount');
    reporter.log('- ⚠️ **Total Issues:** $warnCount');

    if (warnCount == 0) {
      print('\n✨ ${"Everything looks perfect. Your portable vault is healthy.".green.bold}');
    } else {
      if (reindexMode && snapshotsLackingIndex.isNotEmpty) {
        print('\n⚡ ${"Reindexing completed successfully.".magenta.bold}');
      }
      print('\n⚠️  ${"Diagnostics found remaining issues. Review logs above.".yellow.bold}');
    }

    final fileName = 'vcs_doctor_report_${DateTime.now().millisecondsSinceEpoch}.md';
    await reporter.save(fileName);
    
    print('\n📄 ${"Report saved to:".cyan} $fileName');
  }

  Future<void> stats({Map<String, dynamic>? command, List<String> args = const []}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final snapshotsDir = Directory(p.normalize(p.join(context.remoteRepoDir.path, 'snapshots')));
    final indexDir = Directory(p.normalize(p.join(context.remoteRepoDir.path, 'index')));
    
    int totalBytes = 0;
    int indexBytes = 0;
    int indexCount = 0;
    int largestBytes = 0;
    String? largestId;
    int verifiedWithHash = 0;
    final trackSizes = <String, int>{};
    final registeredFiles = <String>{};

    if (snapshotsDir.existsSync()) {
      for (var trackEntry in context.remoteMeta.tracks.entries) {
        int trackTotal = 0;
        
        for (final entry in trackEntry.value.logs) {
          final file = File(p.normalize(p.join(snapshotsDir.path, entry.fileName)));
          final indexFile = File(p.normalize(p.join(indexDir.path, '${entry.id}.json')));
          
          if (await file.exists()) {
            final size = await file.length();
            trackTotal += size;
            totalBytes += size;
            registeredFiles.add('snapshots/${entry.fileName}');
            
            if (entry.hash != null) verifiedWithHash++;

            if (size > largestBytes) {
              largestBytes = size;
              largestId = entry.id;
            }
          }

          if (await indexFile.exists()) {
            indexCount++;
            final iSize = await indexFile.length();
            indexBytes += iSize;
            registeredFiles.add('index/${entry.id}.json');
          }
        }
        trackSizes[trackEntry.key] = trackTotal;
      }
    }

    int orphanBytes = 0;
    int orphanCount = 0;

    Future<void> scanForOrphans(Directory dir, String folderName) async {
      if (dir.existsSync()) {
        await for (var entity in dir.list()) {
          if (entity is File) {
            final name = p.basename(entity.path);
            if (name.startsWith('.tmp_') || name == 'vcs_aliases.json') continue;
            
            final relativePath = '$folderName/$name';
            if (!registeredFiles.contains(relativePath)) {
              orphanBytes += await entity.length();
              orphanCount++;
            }
          }
        }
      }
    }

    await scanForOrphans(snapshotsDir, 'snapshots');
    await scanForOrphans(indexDir, 'index');

    print('\n📊 ${" REPOSITORY STATISTICS ".black.onCyan}');
    print('═' * 60);

    print('${"GENERAL INFO".bold.cyan}');
    print('${"Project Name:".yellow.padRight(22)} ${context.remoteMeta.projectName.green}');
    print('${"Active Track:".yellow.padRight(22)} ${context.remoteMeta.activeTrack.magenta.bold}');
    print('${"Format Version:".yellow.padRight(22)} v${context.remoteMeta.formatVersion}');

    print('\n${"STORAGE SUMMARY".bold.cyan}');
    final totalLogs = context.remoteMeta.tracks.values.fold(0, (prev, t) => prev + t.logs.length);
    print('${"Total Snapshots:".yellow.padRight(22)} ${totalLogs.toString().green}');
    print('${"Snapshot Data:".yellow.padRight(22)} ${_formatBytes(totalBytes).green}');
    
    if (totalLogs > 0) {
      final allLogs = context.remoteMeta.tracks.values.expand((t) => t.logs).toList();
      allLogs.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final firstDate = DateTime.parse(allLogs.first.createdAt);
      final lastDate = DateTime.parse(allLogs.last.createdAt);
      final diffDays = lastDate.difference(firstDate).inDays;
      final growthRate = diffDays > 0 ? totalLogs / diffDays : totalLogs.toDouble();

      print('\n${"PREDICTIVE ANALYSIS".bold.cyan}');
      print('${"Avg. Item Size:".yellow.padRight(22)} ${_formatBytes(totalBytes ~/ totalLogs).white}');
      print('${"Growth Trend:".yellow.padRight(22)} ${growthRate.toStringAsFixed(2)} snapshots/day'.green);
    }
    
    if (indexCount > 0) {
      print('${"Delta Indices:".yellow.padRight(22)} ${_formatBytes(indexBytes).blue} ($indexCount files)');
      final ratio = (indexBytes / (totalBytes > 0 ? totalBytes : 1) * 100).toStringAsFixed(2);
      print('${"Metadata Overhead:".yellow.padRight(22)} $ratio% of total storage');
    }

    print('${"Integrity Coverage:".yellow.padRight(22)} ${((verifiedWithHash / (totalLogs > 0 ? totalLogs : 1)) * 100).toStringAsFixed(1)}% verified');
    
    if (totalLogs > 0) {
      print('${"Largest Snapshot:".yellow.padRight(22)} ${largestId?.green ?? "N/A"} (${_formatBytes(largestBytes)})');
    }

    if (orphanCount > 0) {
      print('${"Unlinked Garbage:".red.padRight(22)} ${_formatBytes(orphanBytes).red} ($orphanCount files)');
      print('   ${"ℹ Tip: Run 'vcs doctor' to safely clean or inspect them.".grey}');
    }

    print('\n${"TAGS & MILESTONES".bold.cyan}');
    if (context.remoteMeta.tags.isEmpty) {
      print('   ${"No tags defined.".grey}');
    } else {
      context.remoteMeta.tags.forEach((tagName, targetId) {
        print('   ${"🏷️  ${tagName.padRight(15)}".yellow} → ${targetId.grey}');
      });
    }

    print('\n${"TRACKS BREAKDOWN".bold.cyan}');
    context.remoteMeta.tracks.forEach((name, state) {
      final isActive = name == context.remoteMeta.activeTrack;
      final prefix = isActive ? ' → '.cyan.bold : '   ';
      final size = _formatBytes(trackSizes[name] ?? 0);
      print('$prefix${name.padRight(18)} ${state.logs.length.toString().padLeft(3)} logs | ${size.padLeft(10)}');
    });

    final bool showCharts = command?['charts'] == true || args.contains('--charts');
    if (showCharts) {
      print('\n${"FILE TYPE DISTRIBUTION".bold.cyan}');
      final activeTrack = context.remoteMeta.activeTrack;
      final lastSnapshotId = context.remoteMeta.tracks[activeTrack]?.logs.lastOrNull?.id;

      if (lastSnapshotId != null) {
        final indexData = await IndexService.loadSnapshotIndex(context.remoteRepoDir, lastSnapshotId);
        if (indexData != null && indexData.isNotEmpty) {
          final extensionMap = <String, int>{};
          for (var path in indexData.keys) {
            final ext = p.extension(path).toLowerCase();
            final label = ext.isEmpty ? 'no-ext' : ext;
            extensionMap[label] = (extensionMap[label] ?? 0) + 1;
          }

          final sortedExts = extensionMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
          final totalFiles = indexData.length;
          const maxBarWidth = 40;

          for (var entry in sortedExts.take(8)) {
            final percent = entry.value / totalFiles;
            final barCount = (percent * maxBarWidth).round();
            final bar = ('█' * barCount).cyan + ('░' * (maxBarWidth - barCount)).grey;
            final label = entry.key.padRight(8);
            final countStr = entry.value.toString().padLeft(4);
            final percentStr = (percent * 100).toStringAsFixed(1).padLeft(5);
            print('   $label $bar $countStr files ($percentStr%)');
          }
          if (sortedExts.length > 8) print('   ${"... others".grey}');
        } else {
          print('   ${"ℹ No index available to generate charts.".grey}');
        }
      } else {
        print('   ${"ℹ No snapshots in active track to analyze.".grey}');
      }
    }

    print('\n${"HEALTH STATUS".bold.cyan}');
    bool isHealthy = orphanCount == 0 && (verifiedWithHash == totalLogs);
    if (isHealthy) {
      print('   ${"Perfectly Synchronized".green}');
      if (indexCount < totalLogs) {
        print('   ${"ℹ Note: ${totalLogs - indexCount} snapshots lack Fast-Diff indices.".blue}');
      }
    } else {
      if (orphanCount > 0) print('   ${"⚠ Found $orphanCount orphan files (unlinked garbage)".yellow}');
      if (verifiedWithHash < totalLogs) print('   ${"⚠ Some snapshots lack integrity hashes".yellow}');
    }

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

    final snapshotsDir = Directory(p.join(context.remoteRepoDir.path, 'snapshots'));
    final indexDir = Directory(p.join(context.remoteRepoDir.path, 'index'));
    final activeTrackName = context.remoteMeta.activeTrack;
    final trackData = context.remoteMeta.tracks[activeTrackName];
    
    if (trackData == null) return;
    final logs = List<SnapshotLogEntry>.from(trackData.logs);

    final toDeleteFiles = <File>[];
    final toDeleteFromLogs = <SnapshotLogEntry>[];
    final tagsToClean = <String>[];
    
    final allTrackLogs = context.remoteMeta.tracks.values.expand((t) => t.logs).toList();
    final allReferencedIds = allTrackLogs.map((e) => e.id).toSet();
    final allReferencedFiles = allTrackLogs.map((e) => e.fileName).toSet();

    if (garbage) {
      print('🔍 ${"Scanning for garbage files...".grey}');
      
      if (snapshotsDir.existsSync()) {
        final physicalFiles = snapshotsDir.listSync().whereType<File>();
        for (final file in physicalFiles) {
          final name = p.basename(file.path);
          if (name.startsWith('.tmp_') || !allReferencedFiles.contains(name)) {
            toDeleteFiles.add(file);
          }
        }
      }

      if (indexDir.existsSync()) {
        final indexFiles = indexDir.listSync().whereType<File>();
        for (final file in indexFiles) {
          final id = p.basenameWithoutExtension(file.path);
          if (!allReferencedIds.contains(id)) {
            toDeleteFiles.add(file);
          }
        }
      }

      context.remoteMeta.tags.forEach((tagName, targetId) {
        if (!allReferencedIds.contains(targetId)) {
          tagsToClean.add(tagName);
        }
      });
    }

    if (snapshotId != null) {
      try {
        final targetEntry = logs.firstWhere((e) => e.id == snapshotId);
        toDeleteFromLogs.add(targetEntry);
      } catch (_) {
        print('❌ Snapshot ID $snapshotId not found in active track.');
        return;
      }
    } else if (keep != null || olderThanDays != null) {
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
        }
      }
    }

    for (var entry in toDeleteFromLogs) {
      final snapshotFile = File(p.join(snapshotsDir.path, entry.fileName));
      if (snapshotFile.existsSync()) {
        if (!toDeleteFiles.any((file) => file.path == snapshotFile.path)) {
          toDeleteFiles.add(snapshotFile);
        }
      }

      final indexFile = File(p.join(indexDir.path, '${entry.id}.json'));
      if (indexFile.existsSync()) {
        if (!toDeleteFiles.any((file) => file.path == indexFile.path)) {
          toDeleteFiles.add(indexFile);
        }
      }
    }

    if (toDeleteFiles.isEmpty && toDeleteFromLogs.isEmpty && tagsToClean.isEmpty) {
      print('✨ ${"Everything is clean. Nothing to prune.".green}');
      return;
    }

    print('\n${"PREPARING CLEANUP:".bold.cyan}');
    if (toDeleteFromLogs.isNotEmpty) print('📦 Snapshots to remove: ${toDeleteFromLogs.length}');
    if (toDeleteFiles.isNotEmpty) print('🗑️  Physical files to delete (Snapshots & Indices): ${toDeleteFiles.length}');
    if (tagsToClean.isNotEmpty) print('🏷️  Orphan tags to remove: ${tagsToClean.length}');

    if (!confirmAction('\nProceed?')) return;

    await _withLock(context.remoteRepoDir, () async {
      for (final file in toDeleteFiles) {
        try { if (await file.exists()) await file.delete(); } catch (_) {}
      }

      final updatedTags = Map<String, String>.from(context.remoteMeta.tags);
      final toDeleteIds = toDeleteFromLogs.map((e) => e.id).toSet();

      updatedTags.removeWhere((name, id) => tagsToClean.contains(name) || toDeleteIds.contains(id));

      List<SnapshotLogEntry> repairedLogs = List.from(logs);
      if (toDeleteFromLogs.isNotEmpty) {
        final deadNodesParents = { for (var e in toDeleteFromLogs) e.id : e.parentId };
        repairedLogs = [];
        for (var entry in logs) {
          if (toDeleteIds.contains(entry.id)) continue;
          var currentParentId = entry.parentId;
          while (deadNodesParents.containsKey(currentParentId)) {
            currentParentId = deadNodesParents[currentParentId];
          }
          repairedLogs.add(entry.copyWith(parentId: currentParentId));
        }
      }

      final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);
      updatedTracks[activeTrackName] = TrackState(
        logs: repairedLogs,
        originSnapshotId: trackData.originSnapshotId,
        originTrackName: trackData.originTrackName,
      );

      final updatedMeta = context.remoteMeta.copyWith(
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        tracks: updatedTracks,
        tags: updatedTags,
      );

      await _atomicWriteString(
        File(p.join(context.remoteRepoDir.path, 'meta.json')),
        const JsonEncoder.withIndent('  ').convert(updatedMeta.toJson()),
      );

      print('\n✅ ${"Cleanup complete!".green.bold}');
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

      try {
        print('🛡️ Running integrity verification...');
        ZipDecoder().decodeBytes(snapshot.zipBytes, verify: true);
        print('✅ ${"Integrity check passed (ZIP valid).".green}');
      } catch (e) {
        print('\n❌ ${"CRITICAL: Snapshot integrity check failed!".red} $e');
        return;
      }

      final archive = ZipDecoder().decodeBytes(snapshot.zipBytes);
      int totalRequiredBytes = 0;
      for (final file in archive) {
        if (file.isFile) totalRequiredBytes += file.size;
      }

      if (!await _hasEnoughStorageSpace(Directory.current, totalRequiredBytes)) {
        print('🚫 Pull aborted to safeguard workspace consistency.'.red);
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

      final visualizer = ProgressVisualizer(
        label: 'Restoring Workspace',
        totalBytes: totalRequiredBytes,
      );

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

        visualizer.update(bytes.length);
        await Future.delayed(Duration.zero);
      }

      visualizer.complete();

      print('\n✅ Pull complete!');
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

    if (!confirmAction(
      '⚠️ This will replace tracked content in the current working directory.\n'
      'A local backup will be created first.\n'
      'Continue?'
    )) {
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

  Future<RepoContext?> loadRepoContext({bool silent = false}) async {
    final usb = await findUsbDrive();
    if (usb == null) {
      if (!silent) print('❌ No prepared USB drive found.');
      return null;
    }

    if (!_localRepoFile.existsSync()) {
      return RepoContext(
        usbDrive: usb,
        remoteRepoDir: Directory(''), 
        localMeta: {},
        remoteMeta: RepoMeta(
          repoId: '',            
          projectName: '', 
          activeTrack: '', 
          tracks: {}, 
          tags: {},
          createdAt: '',         
          updatedAt: '',         
          formatVersion: int.tryParse('4') ?? 4, 
        ),
      );
    }

    try {
      final localMeta = jsonDecode(await _localRepoFile.readAsString()) as Map<String, dynamic>;
      final repoId = localMeta['repo_id']?.toString();
      
      if (repoId == null || repoId.isEmpty) {
        if (!silent) print('❌ Invalid local repo_id.');
        return null;
      }

      final remoteRepoDir = Directory(p.normalize(p.join(usb.path, remoteReposDir, repoId)));
      if (!remoteRepoDir.existsSync()) {
        if (!silent) print('❌ Repo not found on USB drive.');
        return null;
      }

      final metaFile = File(p.join(remoteRepoDir.path, remoteMetaFileName));
      if (!metaFile.existsSync()) {
        if (!silent) print('❌ Remote metadata file is missing.');
        return null;
      }

      final remoteMetaJson = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      return RepoContext(
        usbDrive: usb,
        remoteRepoDir: remoteRepoDir,
        localMeta: localMeta,
        remoteMeta: RepoMeta.fromJson(remoteMetaJson),
      );
    } catch (e) {
      if (!silent) print('❌ Error loading context: $e');
      return null;
    }
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
    String path = input.replaceAll('\\', '/');    
    if (path.startsWith('/')) path = path.substring(1);
    return p.posix.normalize(path);
  }

  Future<Map<String, String>> buildFingerprint(Directory dir, {Map<String, String>? previousFingerprint}) async {
    final out = <String, String>{};
    
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.existsSync()) continue;

      final rel = _normalizeRelativePath(p.relative(entity.path, from: dir.path));
      
      if (await _isIgnoredPath(rel)) continue;

      try {
        final stat = await entity.stat();
        if (stat.size == 0 && rel.endsWith('.old')) continue;

        final currentSize = stat.size;
        String? computedHash;

        if (previousFingerprint != null && previousFingerprint.containsKey(rel)) {
          final cachedData = previousFingerprint[rel]!;
          final parts = cachedData.split('|');
          
          if (parts.length >= 2) {
            final cachedHash = parts[0];
            final cachedSize = int.tryParse(parts[1]) ?? -1;

            if (currentSize == cachedSize) {
              computedHash = cachedHash;
            }
          }
        }

        if (computedHash == null) {
          final bytes = await entity.readAsBytes();
          computedHash = hash.sha256.convert(bytes).toString();
        }

        out[rel] = '$computedHash|$currentSize';

      } catch (e) {
        continue; 
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

  MergeReport analyzeMerge({
    required Map<String, String> baseFingerprint,
    required Map<String, String> localFingerprint,
    required Map<String, String> remoteFingerprint,
    required String baseId,
    required String targetId,
  }) {
    final localChanges = diffFingerprints(baseFingerprint, localFingerprint);
    final remoteChanges = diffFingerprints(baseFingerprint, remoteFingerprint);

    final localMap = {for (var c in localChanges) c.path: c.kind};
    final remoteMap = {for (var c in remoteChanges) c.path: c.kind};

    final conflicts = <MergeConflict>[];
    final safeFiles = <String>[];

    final allPaths = {...baseFingerprint.keys, ...localFingerprint.keys, ...remoteFingerprint.keys};

    for (final path in allPaths) {
      final hasLocalChange = localMap.containsKey(path);
      final hasRemoteChange = remoteMap.containsKey(path);

      if (hasLocalChange && hasRemoteChange) {
        if (localFingerprint[path] == remoteFingerprint[path]) {
          safeFiles.add(path);
        } else {          
          conflicts.add(MergeConflict(
            filePath: path,
            conflictedScopes: ["Divergent content modification"],
            baseHash: baseFingerprint[path],
            localHash: localFingerprint[path],
            remoteHash: remoteFingerprint[path],
          ));
        }
      } 
      else {
        safeFiles.add(path);
      }
    }

    return MergeReport(
      baseSnapshotId: baseId,
      targetSnapshotId: targetId,
      safeFiles: safeFiles,
      conflicts: conflicts,
    );
  }

  Future<void> mergeCheck(String targetTrackName, {String? password}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final currentTrack = context.remoteMeta.activeTrack;
    
    if (currentTrack == targetTrackName) {
      print('ℹ️  You are already on track "$targetTrackName". Nothing to merge.');
      return;
    }

    final finalPassword = password ?? askPassword();
    if (finalPassword == null || finalPassword.isEmpty) {
      print('❌ Password required for merge analysis.');
      return;
    }

    print('🔍 Analyzing merge: ${currentTrack.cyan} ← ${targetTrackName.yellow}');

    final baseSnapshotId = findCommonAncestor(
      context.remoteMeta, 
      currentTrack, 
      targetTrackName
    );

    if (baseSnapshotId == null) {
      print('❌ ${'No common ancestor found'.red}. Tracks have diverged completely.');
      return;
    }

    final localSnapshotId = context.remoteMeta.tracks[currentTrack]!.logs.first.id;
    final remoteSnapshotId = context.remoteMeta.tracks[targetTrackName]!.logs.first.id;

    final baseFingerprint = await _getSnapshotFingerprint(context, baseSnapshotId, finalPassword);
    final localFingerprint = await _getSnapshotFingerprint(context, localSnapshotId, finalPassword);
    final remoteFingerprint = await _getSnapshotFingerprint(context, remoteSnapshotId, finalPassword);

    final report = analyzeMerge(
      baseFingerprint: baseFingerprint,
      localFingerprint: localFingerprint,
      remoteFingerprint: remoteFingerprint,
      baseId: baseSnapshotId,
      targetId: remoteSnapshotId,
    );

    await _displayMergeReport(context, report, targetTrackName, finalPassword);
  }

  String? findCommonAncestor(RepoMeta meta, String trackA, String trackB) {
    final logsA = meta.tracks[trackA]?.logs ?? [];
    final logsB = meta.tracks[trackB]?.logs ?? [];

    if (logsA.isEmpty || logsB.isEmpty) return null;

    SnapshotLogEntry? findLogById(String id) {
      for (final track in meta.tracks.values) {
        final log = track.logs.firstWhere((l) => l.id == id, orElse: () => 
                    SnapshotLogEntry(id: 'dummy', message: '', author: null, createdAt: '', fileName: '', changeSummary: []));
        if (log.id != 'dummy') return log;
      }
      return null;
    }

    final Set<String> ancestorsA = {};
    String? currentA = logsA.first.id;
    
    while (currentA != null) {
      ancestorsA.add(currentA);
      final log = findLogById(currentA);
      currentA = (log != null) ? log.parentId : null;
    }

    String? currentB = logsB.first.id;
    while (currentB != null) {
      if (ancestorsA.contains(currentB)) return currentB;
      
      final log = findLogById(currentB);
      currentB = (log != null) ? log.parentId : null;
    }

    return null;
  }

  Future<Map<String, String>> _getSnapshotFingerprint(
    RepoContext context, 
    String id, 
    String password
  ) async {
    SnapshotLogEntry? entry;
    for (final track in context.remoteMeta.tracks.values) {
      for (final log in track.logs) {
        if (log.id == id) {
          entry = log;
          break;
        }
      }
      if (entry != null) break;
    }

    if (entry == null) return {};

    final snap = await readSnapshotByMeta(
      remoteRepoDir: context.remoteRepoDir, 
      remoteMeta: context.remoteMeta, 
      snapshotId: id, 
      password: password,
      silent: true
    );

    return snap?.fingerprint ?? {};
  }

  Future<void> _displayMergeReport(
    RepoContext context, 
    MergeReport report, 
    String targetTrack, 
    String password,
  ) async {
    print('\n════════════════════════════════════════════════════════════');
    print(' 🛡️  PRE-MERGE ANALYSIS REPORT (Read-Only)');
    print('════════════════════════════════════════════════════════════\n');

    print('${'Common Base:'.padRight(15)} ${report.baseSnapshotId.grey}');
    print('${'Merging:'.padRight(15)} ${targetTrack.yellow}');
    
    if (report.hasConflicts) {
      print('\n${'⚠️  CONFLICTS DETECTED:'.red.bold} ${report.conflicts.length} files overlap');
      
      for (final conflict in report.conflicts) {
        print('\n  ${'×'.red} ${conflict.filePath.white.bold}');
        
        if (conflict.filePath.endsWith('.dart') || 
            conflict.filePath.endsWith('.js') || 
            conflict.filePath.endsWith('.ts')) {
          
          final scopes = await _detectConflictingScopes(context, report, conflict.filePath, password);
          
          if (scopes.isNotEmpty) {
            print('      ${"Potential collision in:".grey}');
            for (final s in scopes) {
              print('      ${"•".yellow} ${s}');
            }
          } else {
            print('      ${"•".grey} Non-structural or global change detected.');
          }
        } else {
          print('      ${"•".grey} Binary or data file conflict.');
        }
      }
    } else {
      print('\n${'✅ CLEAN MERGE:'.green.bold} All changes can be auto-applied.');
    }

    print('\n${'Summary Stats:'.white.underline}');
    print('  ${'•'.green} ${report.safeFiles.length.toString().padLeft(3)} files can be auto-merged.');
    print('  ${'•'.red} ${report.conflicts.length.toString().padLeft(3)} files require manual resolution.');
    
    print('\n${'ℹ️  PREVIEW MODE:'.cyan} No changes have been written to disk.');
    print('To complete the merge after checking, use: ${'vcs merge apply <track>'.bold}');
    print('════════════════════════════════════════════════════════════\n');
  }

  Future<MergeReport?> generateMergeReport(
    String targetTrackName, 
    {String? password, String? forcedBaseId}
  ) async {
    print('📂 ${"Initializing repository context...".grey}');
    final context = await loadRepoContext();
    if (context == null) {
      print('❌ ${"Error: Could not load repository context. Ensure you are in a valid VCS project.".red}');
      return null;
    }

    final currentTrack = context.remoteMeta.activeTrack;
    final finalPassword = password ?? askPassword();
    if (finalPassword == null) {
      print('❌ ${"Authentication failed: Password required.".red}');
      return null;
    }

    String? baseSnapshotId;

    if (forcedBaseId != null) {
      print('💡 ${"Using manual ancestor ID:".cyan} $forcedBaseId');
      baseSnapshotId = forcedBaseId;
    } else {
      print('🔍 ${"Analyzing lineage between".grey} ${currentTrack.cyan} ${"and".grey} ${targetTrackName.yellow}...');
      baseSnapshotId = findCommonAncestor(context.remoteMeta, currentTrack, targetTrackName);
      
      if (baseSnapshotId == null) {
        print('⚠️ ${"No common ancestor found.".yellow}');
        print('   ${"Hint: Only tracks with a shared snapshot history can be merged.".grey}');
        print('   ${"Use --id <snapshot_id> to manually specify an ancestor.".grey}');
        return null;
      }
    }

    print('🔗 ${"Common ancestor identified:".green} $baseSnapshotId');

    final localSnapshotId = context.remoteMeta.tracks[currentTrack]!.logs.first.id;
    final remoteSnapshotId = context.remoteMeta.tracks[targetTrackName]!.logs.first.id;

    print('⚡ ${"Computing snapshot fingerprints...".grey}');
    
    final results = await Future.wait([
      _getSnapshotFingerprint(context, baseSnapshotId, finalPassword),
      _getSnapshotFingerprint(context, localSnapshotId, finalPassword),
      _getSnapshotFingerprint(context, remoteSnapshotId, finalPassword),
    ]);

    print('✅ ${"Analysis complete.".green}');

    return analyzeMerge(
      baseFingerprint: results[0],
      localFingerprint: results[1],
      remoteFingerprint: results[2],
      baseId: baseSnapshotId,
      targetId: remoteSnapshotId,
    );
  }

  Future<Uint8List> _getRemoteFileContent(String trackName, String filePath, String password) async {
    final context = await loadRepoContext();
    final log = context!.remoteMeta.tracks[trackName]!.logs.first;
    
    final snap = await readSnapshotByMeta(
      remoteRepoDir: context.remoteRepoDir,
      remoteMeta: context.remoteMeta,
      snapshotId: log.id,
      password: password,
      silent: true
    );

    final files = await _decodeSnapshotFiles(snap!);
    return files[filePath]!;
  }

  Future<void> mergeApply(String targetTrackName, {String? password, String? manualBaseId}) async {
    final pwd = password ?? askPassword();
    if (pwd == null) return;

    final report = await generateMergeReport(
      targetTrackName, 
      password: pwd, 
      forcedBaseId: manualBaseId
    );
    
    if (report == null) return;

    if (report.hasConflicts) {
      print('❌ ${"Merge aborted: Conflicts detected.".red}');
      print('\n📝 ${"Conflict details for files:".yellow.bold}');
      print('----------------------------------------------------');
      
      for (final conflict in report.conflicts) {
        print('📂 ${"File:".cyan} ${conflict.filePath}');
        print('   ${"Hashes:".grey}');
        print('    • Base:   ${conflict.baseHash ?? "NULL"}');
        print('    • Local:  ${conflict.localHash ?? "NULL"}');
        print('    • Remote: ${conflict.remoteHash ?? "NULL"}');

        if (conflict.conflictedScopes.isNotEmpty) {
          print('   ${"Reasons:".grey}');
          for (final scope in conflict.conflictedScopes) {
            print('    • $scope');
          }
        } else {
          print('   ${"Reasons:".grey} ${"Irreconcilable divergent modifications.".italic}');
        }
        print('');
      }
      
      print('----------------------------------------------------');
      print('💡 ${"Tip: Review the listed files or use --id to verify the merge base.".grey}');
      return;
    }

    final sandboxDir = Directory.systemTemp.createTempSync('vcs_merge_sandbox_');
    print('🏗️ ${"Staging merge in sandbox...".cyan} ${sandboxDir.path}');

    await _copyDirectory(_cwd, sandboxDir);

    for (final path in report.safeFiles) {
      final content = await _getRemoteFileContent(targetTrackName, path, pwd);
      final file = File(p.join(sandboxDir.path, path));
      await file.create(recursive: true);
      await file.writeAsBytes(content);
    }

    print('🚀 ${"Opening sandbox in VS Code...".cyan}');
    final result = await Process.run('code', [sandboxDir.path]);
    if (result.exitCode != 0) {
      print('⚠️ ${"Could not open VS Code. Please ensure 'code' is in your system PATH.".yellow}');
      print('   ${"Sandbox location:".grey} ${sandboxDir.path}');
    }

    stdout.write('\n❓ ${"Review the changes. Apply to main project? (y/N): ".yellow}');
    final input = stdin.readLineSync()?.toLowerCase();

    if (input == 'y') {
      for (final path in report.safeFiles) {
        final content = await File(p.join(sandboxDir.path, path)).readAsBytes();
        final targetFile = File(p.join(_cwd.path, path));
        await targetFile.create(recursive: true);
        await targetFile.writeAsBytes(content);
      }
      print('\n✅ ${"Merge successfully applied!".green}');
      print('📄 ${"Summary:".bold} ${report.safeFiles.length} ${"files updated from".grey} $targetTrackName.');
    } else {
      print('🚫 ${"Merge aborted by user.".red}');
    }

    await sandboxDir.delete(recursive: true);
  }

  Future<List<String>> _detectConflictingScopes(
    RepoContext context, 
    MergeReport report, 
    String path, 
    String password,
  ) async {
    final scopes = <String>{};
    final regex = RegExp(r'(class|void|Future|static|async|get|set)\s+([a-zA-Z0-9_]+)');

    try {
      final remoteSnap = await readSnapshotByMeta(
        remoteRepoDir: context.remoteRepoDir,
        remoteMeta: context.remoteMeta,
        snapshotId: report.targetSnapshotId,
        password: password,
        silent: true,
      );

      if (remoteSnap != null) {
        final remoteFiles = await _decodeSnapshotFiles(remoteSnap);
        final remoteFileData = remoteFiles[path];

        if (remoteFileData != null) {
          final remoteContent = utf8.decode(remoteFileData, allowMalformed: true);
          
          final localFile = File(path);
          String localContent = '';
          if (await localFile.exists()) {
            localContent = await localFile.readAsString();
          }

          for (final content in [localContent, remoteContent]) {
            final matches = regex.allMatches(content);
            for (final m in matches) {
              final type = m.group(1);
              final name = m.group(2);
              if (name != null) {
                scopes.add('$type $name');
              }
            }
          }
        }
      }
    } catch (e) {
      return [];
    }

    return scopes.take(5).toList();
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
    String? trackName,
    String? parentId,
    Map<String, String>? fingerprint,
    String? author,
  }) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(List<int>.generate(16, (_) => random.nextInt(256)));
    final nonce = Uint8List.fromList(List<int>.generate(12, (_) => random.nextInt(256)));

    final algorithm = crypto_alg.Pbkdf2(
      macAlgorithm: crypto_alg.Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    );
    final secretKey = await algorithm.deriveKeyFromPassword(password: password, nonce: salt);

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
    final secretBox = await aes.encrypt(plainBytes, secretKey: secretKey, nonce: nonce);

    final wrapper = {
      'alg': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': 120000,
      'salt_b64': base64Encode(salt),
      'nonce_b64': base64Encode(secretBox.nonce),
      'cipher_b64': base64Encode(secretBox.cipherText),
      'mac_b64': base64Encode(secretBox.mac.bytes),
    };

    final recoveryHeader = {
      'vcs_recovery': '0.3.7',
      'track': trackName ?? 'release',
      'parent': parentId ?? 'none',
      'author': author ?? 'unknown',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    final fullContent = 
        jsonEncode(recoveryHeader) + "\n---VCS_DATA_START---\n" + jsonEncode(wrapper);

    return Uint8List.fromList(utf8.encode(fullContent));
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
      final fileContent = await file.readAsString();
      Map<String, dynamic> raw;

      if (fileContent.contains('---VCS_DATA_START---')) {
        final parts = fileContent.split('---VCS_DATA_START---');
        final jsonString = parts.sublist(1).join('---VCS_DATA_START---').trim();
        raw = jsonDecode(jsonString) as Map<String, dynamic>;
      } else {
        raw = jsonDecode(fileContent.trim()) as Map<String, dynamic>;
      }

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
    final password = _readHiddenLine().trim();
    stdout.writeln();

    if (password.isEmpty) {
      try {
        ProcessResult result;
        if (Platform.isWindows) {
          result = Process.runSync('powershell', ['-Command', 'Get-Clipboard']);
        } else if (Platform.isMacOS) {
          result = Process.runSync('pbpaste', []);
        } else {
          result = Process.runSync('xclip', ['-selection', 'clipboard', '-o']);
        }

        if (result.exitCode == 0) {
          final clipboardData = result.stdout.toString().trim();
          if (clipboardData.isNotEmpty) {
            print('📋 ${"Password securely injected from clipboard.".green}');
            return clipboardData;
          }
        }
      } catch (_) {}

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

    final sb = StringBuffer();
    sb.writeln("# TIMELINE: [[ ${targetTrack.toUpperCase()} ]]");
    sb.writeln("> Showing last $limit snapshots from the repository history.\n");

    final logsToShow = trackData.logs.reversed.take(limit).toList();

    for (var entry in logsToShow) {
      final String sId = entry.id.toString();
      final String shortId = sId.length > 8 ? sId.substring(0, 8) : sId;
      final date = DateTime.parse(entry.createdAt).toLocal().toString().substring(0, 16);
      
      String tags = "";
      context.remoteMeta.tags.forEach((tag, id) {
        if (id == sId) tags += " [[ YELLOW: 🏷️ $tag ]]";
      });

      sb.writeln("## [[ grey: $shortId ]] | $date");
      sb.writeln("${entry.message.bold}$tags");

      if (entry.notes.isNotEmpty) {
        for (var note in entry.notes) {
          sb.writeln("> [[ grey: 📝 ${note.author}: ]] ${note.text}");
        }
      }
      sb.writeln(""); 
    }

    print(_renderMarkdown(sb.toString()));
  }

  Future<void> openTarget(String? target) async {
    final context = await loadRepoContext(silent: true);
    
    if (target == null || target.isEmpty) {
      await _launch(Directory.current.path, useCode: true);
      return;
    }

    if (target.toLowerCase() == 'usb' && context != null) {
      await _launch(context.usbDrive.path);
      return;
    }

    String? foundPath;
    bool useCode = false;

    final localFolder = Directory(p.join(Directory.current.path, target));
    if (localFolder.existsSync()) {
      foundPath = localFolder.path;
      useCode = true;
    } 
    
    if (foundPath == null && context != null) {
      final remoteBaseDir = Directory(p.join(context.usbDrive.path, remoteReposDir));
      if (remoteBaseDir.existsSync()) {
        for (var entity in remoteBaseDir.listSync().whereType<Directory>()) {
          final metaFile = File(p.join(entity.path, remoteMetaFileName));
          if (metaFile.existsSync()) {
            try {
              final metaJson = jsonDecode(await metaFile.readAsString());
              if (metaJson['project_name']?.toString().toLowerCase() == target.toLowerCase()) {
                foundPath = entity.path;
                break;
              }
            } catch (_) {}
          }
        }
      }
    }

    if (foundPath != null) {
      await _launch(foundPath, useCode: useCode);
    } else {
      print('❌ ${"Error:".red} Project "$target" not found locally or on USB.');
    }
  }

  Future<void> _launch(String path, {bool useCode = false}) async {
    final Directory dir = Directory(path).absolute;
    String nativePath = p.normalize(dir.path);

    if (!dir.existsSync()) {
      print('❌ ${"Error:".red} Path does not exist: $nativePath');
      return;
    }

    print('🚀 ${"Launching:".cyan} $nativePath');

    try {
      if (Platform.isWindows) {
        if (useCode) {
          await Process.run('cmd', ['/c', 'code', nativePath], runInShell: true);
        } else {
          await Process.run('cmd', ['/c', 'start', '""', nativePath], runInShell: true);
        }
      } else if (Platform.isMacOS) {
        await Process.run(useCode ? 'code' : 'open', [nativePath]);
      } else {
        await Process.run('xdg-open', [nativePath]);
      }
    } catch (e) {
      print('❌ Failed to launch: $e');
    }
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

    List<String> paths = [];

    final cachedIndex = await IndexService.loadSnapshotIndex(context.remoteRepoDir, targetId);
    
    if (cachedIndex != null) {
      print('⚡ ${"Fast-loading tree from index...".grey}');
      paths = cachedIndex.keys.toList()..sort();
    } else {
      print('🔒 ${"Index not found. Decryption required...".yellow}');
      final password = askPassword();
      if (password == null) return;

      final snapshot = await readSnapshot(context, targetId, password: password);
      if (snapshot == null) return;

      final files = await _decodeSnapshotFiles(snapshot);
      paths = files.keys.toList()..sort();
      
      await IndexService.saveSnapshotIndex(
        remoteRepoDir: context.remoteRepoDir, 
        snapshotId: targetId, 
        fileMap: Map<String, String>.from(snapshot.fingerprint)
      );
    }

    final treeStats = TreeStats();

    print('\n🌳 ${"SNAPSHOT FILE TREE".black.onCyan}');
    print('═' * 60);
    print('${"Snapshot:".yellow.padRight(12)} ${entry.id.green} (${entry.message.grey})');
    print('${"Track:".yellow.padRight(12)} ${targetTrackName.magenta.bold}');
    print('${"Created:".yellow.padRight(12)} ${_formatDateForList(entry.createdAt)}');
    if (cachedIndex != null) print('${"Source:".yellow.padRight(12)} ${"Delta-Index (Instant)".cyan}');
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
        if (a.isFile != b.isFile) return a.isFile ? 1 : -1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    for (var i = 0; i < entries.length; i++) {
      final child = entries[i];
      final isLast = i == entries.length - 1;
      final branch = isLast ? '└── ' : '├── ';

      if (child.isFile) {
        stats.files++;
        final icon = _getFileIcon(child.name);
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

  String _getFileIcon(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    switch (ext) {
      case '.dart': return '🎯';
      case '.json':
      case '.yaml':
      case '.toml': return '⚙️';
      case '.md':   return '📝';
      case '.txt':  return '📄';
      case '.exe':
      case '.sh':
      case '.bat':  return '⚡';
      case '.jpg':
      case '.png':
      case '.svg':  return '🖼️';
      default:      return '📄';
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

  Future<void> trackCreate(String name, {String? fromSnapshot}) async {
    final context = await loadRepoContext();
    if (context == null) return;

    final trackName = name.trim();
    final activeTrackName = context.remoteMeta.activeTrack;
    final activeTrack = context.remoteMeta.tracks[activeTrackName];

    if (!_isValidTrackName(trackName)) {
      print('❌ ${"Invalid track name.".red} Use only alphanumeric, "_" or "-".');
      return;
    }

    if (context.remoteMeta.tracks.containsKey(trackName)) {
      print('❌ ${"Track already exists:".red} $trackName');
      return;
    }

    String? originId = fromSnapshot;
    SnapshotLogEntry? initialEntry;

    if (originId == null && activeTrack != null && activeTrack.logs.isNotEmpty) {
      initialEntry = activeTrack.logs.first;
      originId = initialEntry.id;
    } else if (originId != null) {
      initialEntry = _findEntryInAllTracks(context.remoteMeta, originId);
    }

    final updatedTracks = Map<String, TrackState>.from(context.remoteMeta.tracks);

    updatedTracks[trackName] = TrackState(
      logs: initialEntry != null ? [initialEntry] : [], 
      originSnapshotId: originId,
      originTrackName: activeTrackName,
    );

    final updatedMeta = context.remoteMeta.copyWith(
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      tracks: updatedTracks,
    );

    await _saveRemoteMeta(context, updatedMeta);

    print('✅ ${"Track created:".green} $trackName');
    if (initialEntry != null) {
      print('ℹ️  ${"Origin:".grey} Branching from $activeTrackName at ${initialEntry.id.substring(0, 8)}...');
      print('ℹ️  ${"Status:".grey} Track initialized with ${initialEntry.message}');
    } else {
      print('ℹ️  ${"Origin:".grey} Empty track (Root).');
    }
  }

  SnapshotLogEntry? _findEntryInAllTracks(RepoMeta meta, String id) {
    for (final track in meta.tracks.values) {
      for (final entry in track.logs) {
        if (entry.id == id) return entry;
      }
    }
    return null;
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

    print('🧪 Preparing shadow workspace for: $targetTrackName'.cyan);
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
        print('❌ Password required.'.red);
        return; 
      }

      print('📥 Extracting last snapshot to LOCAL storage...'.cyan);
      
      final lastSnapshot = await readSnapshot(
        context, 
        trackData.logs.first.id, 
        password: effectivePassword, 
      );

      if (lastSnapshot != null) {
        final archive = ZipDecoder().decodeBytes(lastSnapshot.zipBytes);

        int totalRequiredBytes = 0;
        for (final file in archive) {
          if (file.isFile) totalRequiredBytes += file.size;
        }

        if (!await _hasEnoughStorageSpace(shadowDir, totalRequiredBytes)) {
          print('🚫 Switch aborted: Not enough space to deploy shadow workspace.'.red);
          return;
        }

        for (final file in archive) {
          if (file.isFile) {
            final outFile = File(p.join(shadowPath, file.name));
            await outFile.create(recursive: true);
            await outFile.writeAsBytes(file.content as List<int>);
          }
        }
        print('✅ Content restored locally.'.green);
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
        author: "VCS-Benchmark",
        trackName: "benchmark-track",
        parentId: "bench-origin",
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
      } catch (_) {
        // Silent Error
      }
    }

    if (cachedLatest != null && isUpdateAvailable(vcsBaseVersion, cachedLatest)) {
      _printUpdateToast(vcsBaseVersion, cachedLatest);
    }

    final bool isFirstTime = lastCheck == null;
    final bool isExpired = !isFirstTime && DateTime.now().difference(lastCheck).inHours >= 24;

    void triggerBackgroundFetch() {
      _getLatestGitHubVersion().timeout(const Duration(seconds: 3)).then((latestV) async {
        if (latestV != null) {
          final data = '$latestV\n${DateTime.now().toIso8601String()}';
          try {
            await cacheFile.writeAsString(data, mode: FileMode.write, flush: true);
          } catch (_) {}
        }
      }).catchError((_) {});
    }

    if (isFirstTime || isExpired) {
      triggerBackgroundFetch();
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

  Future<bool> isFileIgnored(String path, Directory rootDir, List<IgnoreRule> rules) async {
    final relativePath = p.relative(path, from: rootDir.path);
    final basename = p.basename(path);
    
    bool ignored = false;
    for (final rule in rules) {
      if (rule.matches(relativePath, basename)) {
        ignored = !rule.negated;
      }
    }
    return ignored;
  }

  Future<void> createRelease(String message) async {
    final context = await loadRepoContext();
    if (context == null) return;

    stdout.write('🏷️  Enter version tag (e.g., v1.0.1): ');
    final version = stdin.readLineSync()?.trim() ?? 'v0.0.0';

    final releaseId = DateTime.now().millisecondsSinceEpoch.toString();
    final releaseService = ReleaseService(context.remoteRepoDir);
    await releaseService.ensureInitialized();

    final releaseFolder = Directory(p.join(releaseService.releasesDir.path, releaseId));
    await releaseFolder.create(recursive: true);

    print('📦 Preparing release archive using existing VCS rules...');

    final zipBytes = await _createZipFromCurrentProject(sourcePath: _cwd);

    final password = askPassword();
    if (password == null) {
      print('❌ Encryption cancelled.');
      await releaseFolder.delete(recursive: true);
      return;
    }

    final encryptedData = await _encryptSnapshot(
      zipBytes: zipBytes,
      message: message,
      password: password,
      trackName: 'release', 
      author: 'system',
    );

    final snapshotPath = p.join(releaseFolder.path, 'archive.enc');
    await File(snapshotPath).writeAsBytes(encryptedData);

    final manifest = {
      'version': version,
      'releaseId': releaseId,
      'message': message,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    await File(p.join(releaseFolder.path, 'manifest.json'))
        .writeAsString(jsonEncode(manifest), flush: true);

    await releaseService.appendReleaseToIndex(ReleaseEntry(
      version: version,
      releaseId: releaseId,
      message: message,
      snapshotPath: snapshotPath,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));

    print('🚀 ${"Release $version successfully created!".green.bold}');
  }

  ReleaseService? _releaseService;
  
  Future<ReleaseService> getReleaseService(Directory repoDir) async {
    if (_releaseService == null || _releaseService!.repoDir.path != repoDir.path) {
      _releaseService = ReleaseService(repoDir);
      await _releaseService!.ensureInitialized();
    }
    return _releaseService!;
  }

  Future<void> releasePublic(String releaseId) async {
    final context = await loadRepoContext();
    if (context == null) return;
    final service = await getReleaseService(context.remoteRepoDir);
    final password = askPassword();
    if (password != null) {
      await service.releasePublic(releaseId, password);
    }
  }

  Future<void> listReleases() async {
    final context = await loadRepoContext();
    if (context == null) return;
    final service = await getReleaseService(context.remoteRepoDir);
    await service.listReleases();
  }

  Future<void> deleteRelease(String releaseId) async {
    final context = await loadRepoContext();
    if (context == null) return;
    final service = await getReleaseService(context.remoteRepoDir);
    await service.deleteRelease(releaseId);
  }

  Future<void> inspect([String? snapshotId]) async {
    final context = await loadRepoContext();
    if (context == null) return;
    final meta = context.remoteMeta;

    SnapshotLogEntry? entry;
    String? foundTrack;

    if (snapshotId == null) {
      final activeTrackName = meta.activeTrack;
      final trackData = meta.tracks[activeTrackName];
      
      if (trackData != null && trackData.logs.isNotEmpty) {
        entry = trackData.logs.first;
        foundTrack = activeTrackName;
      } else {
        print('❌ ${"Error:".red} No snapshots found in active track "$activeTrackName".');
        return;
      }
    } else {
      for (final track in meta.tracks.entries) {
        final match = track.value.logs.firstWhere(
          (log) => log.id == snapshotId,
          orElse: () => null as SnapshotLogEntry,
        );
        
        if (match != null && match.id == snapshotId) {
          entry = match;
          foundTrack = track.key;
          break;
        }
      }
    }

    if (entry == null) {
      print('\n❌ ${"Error:".red} Snapshot "${snapshotId ?? 'N/A'}" not found.');
      return;
    }

    print('\n${"══════════════════════════════════════════════════════".magenta}');
    print('   🔍 ${"VCS INSPECTION REPORT".bold.cyan}');
    print('${"══════════════════════════════════════════════════════".magenta}\n');

    print('${"Project:".padRight(16).bold.blue} ${meta.projectName}');
    print('${"Repo ID:".padRight(16).bold.blue} ${meta.repoId.gray}');
    print('${"Format Ver:".padRight(16).bold.blue} ${meta.formatVersion}');
    print('${"Total Tracks:".padRight(16).bold.blue} ${meta.tracks.length}');
    print('${"Global Tags:".padRight(16).bold.blue} ${meta.tags.isEmpty ? "None" : meta.tags.keys.join(", ")}');
    print('');

    print('${"Snapshot ID:".padRight(16).bold.yellow} ${entry.id}');
    print('${"Track:".padRight(16).bold} ${foundTrack?.blue ?? 'unknown'}');
    print('${"Message:".padRight(16).bold} ${entry.message.green}');
    print('${"Author:".padRight(16).bold} ${entry.author?.white ?? 'unknown'}');
    print('${"Date:".padRight(16).bold} ${entry.createdAt.italic}');
    print('${"Parent ID:".padRight(16).bold} ${entry.parentId?.yellow ?? 'None'}');
    print('${"File Name:".padRight(16).bold} ${entry.fileName.gray}');
    
    if (entry.hasIntegrityData) {
      print('${"Hash (SHA256):".padRight(16).bold} ${entry.hash!.magenta}');
    }

    print('\n${"Change Summary:".bold.yellow}');
    if (entry.changeSummary.isEmpty) {
      print('  ${"No changes recorded".gray}');
    } else {
      for (var change in entry.changeSummary) {
        if (change.contains('[M]')) print('  • ${"[M]".yellow} ${change.substring(3).trim()}');
        else if (change.contains('[N]')) print('  • ${"[N]".green} ${change.substring(3).trim()}');
        else if (change.contains('[D]')) print('  • ${"[D]".red} ${change.substring(3).trim()}');
        else print('  • $change');
      }
    }

    print('\n${"Notes:".bold.yellow}');
    if (entry.notes.isEmpty) {
      print('  ${"No notes available".gray}');
    } else {
      for (var note in entry.notes) {
        print('  • ${note.createdAt.italic.gray} | ${note.text}');
      }
    }
    print('\n${"══════════════════════════════════════════════════════".magenta}\n');
  }

  Future<void> export(String snapshotId, String outputPath) async {
    String finalPath = outputPath;
    if (!finalPath.toLowerCase().endsWith('.zip')) {
      finalPath += '.zip';
    }

    final file = File(finalPath);
    if (await file.exists()) {
      print('⚠️  ${"File already exists:".yellow} $finalPath');
      if (!confirmAction('Overwrite existing file?')) {
        print('❌ ${"Export cancelled.".red}');
        return;
      }
    }

    final context = await loadRepoContext();
    if (context == null) return;

    print('⏳ ${"Preparing export for snapshot:".yellow} $snapshotId');
    final password = askPassword();
    if (password == null) return;

    final snapshot = await readSnapshot(context, snapshotId, password: password);
    if (snapshot == null) {
      print('❌ ${"Failed to decrypt snapshot.".red}');
      return;
    }

    final files = await _decodeSnapshotFiles(snapshot);
    
    final encoder = ZipFileEncoder();
    encoder.create(finalPath);

    print('📦 ${"Compressing files...".cyan}');
    for (final entry in files.entries) {
      encoder.addArchiveFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    encoder.close();

    print('✅ ${"Export completed successfully!".green}');
    print('   ${"Location:".grey} $finalPath');
  }

  Future<void> import(String zipPath, String targetTrack) async {
    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      print('❌ ${"File not found:".red} $zipPath');
      return;
    }

    final zipName = p.basenameWithoutExtension(zipPath);
    print('📦 ${"Starting import of:".cyan} $zipName');

    final tempDir = Directory(p.join(Directory.systemTemp.path, '$zipName'));
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create();

    try {
      print('⏳ ${"Extracting contents...".yellow}');
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      
      for (final file in archive) {
        if (file.isFile) {
          final outFile = File(p.join(tempDir.path, file.name));
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }

      final contents = tempDir.listSync();
      if (contents.length == 1 && contents.first is Directory) {
        final subDir = contents.first as Directory;
        print('🔍 ${"Detected nested folder, flattening structure...".cyan}');
        for (var item in subDir.listSync()) {
          final newPath = p.join(tempDir.path, p.basename(item.path));
          await item.rename(newPath);
        }
        await subDir.delete();
      }

      setShadowContext(tempDir.path);

      final vcsDir = Directory(p.join(tempDir.path, localMetaDirName));
      if (!await vcsDir.exists()) {
        print('🏗️ ${"Initializing repository structure...".yellow}');
        await init();
      }

      print('🚀 ${"Syncing to Vault...".cyan}');
      await push(
        "Imported from $zipPath",
        track: targetTrack,
        overrideSourcePath: tempDir.path,
        skipConfirm: true,
      );

      print('✅ ${"Import completed successfully!".green}');
    } catch (e) {
      print('❌ ${"Import failed:".red} $e');
    } finally {
      _forcedCwd = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  }
}

class RoadmapCommand {
  static Future<void> handle(List<String> args, dynamic context, {String? taskTag}) async {
    if (args.isEmpty) {
      _displayRoadmap(context);
      return;
    }

    final roadmap = RoadmapManager.load(context);
    final action = args[0].toLowerCase();

    switch (action) {
      case 'init':
      case 'edit':
        final file = File(p.join(context.remoteRepoDir.path, 'roadmap.json'));
        
        if (!file.existsSync()) {
          print('✨ Creating a new strategic roadmap from template...');
          RoadmapManager.initializeTemplate(context);
        } else {
          print('🔄 Roadmap detected. Opening your active project planner...');
        }

        print('\n📌 ${"EXPECTED JSON STRUCTURE EXAMPLE:".bold.cyan}');
        print('${" [".grey}');
        print('${"   {".grey}');
        print('     ${"\"version\"".cyan}: ${"\"1.0.0-Beta\"".green},');
        print('     ${"\"title\"".cyan}: ${"\"Core Implementation\"".green},');
        print('     ${"\"tasks\"".cyan}: [');
        print('       {');
        print('         ${"\"id\"".cyan}: ${"\"TSK-001\"".yellow},');
        print('         ${"\"description\"".cyan}: ${"\"Database indexing migration\"".green},');
        print('         ${"\"tag\"".cyan}: ${"\"DB\"".magenta},');
        print('         ${"\"isDone\"".cyan}: ${"false".red}');
        print('       }');
        print('     ]');
        print('${"   }".grey}');
        print('${" ]".grey}');
        
        print('\n📊 ${"HOW IT WILL RENDER IN YOUR TERMINAL:".bold.yellow}');
        print(' 📦 Version ${"1.0.0-Beta".green.bold} - ${"Core Implementation".white}');
        print('  └── [${"TSK-001".cyan}] <${"DB".magenta}> Database indexing migration${" [TODO]".yellow}');
        
        print('\n⚠️  ${"Strict JSON Reminder:".red} Strings must use double-quotes. Avoid trailing commas.\n');

        print('📝 Opening ${"roadmap.json".cyan} in your system editor...');
        await _openSystemEditor(file.path);

        try {
          final testLoad = RoadmapManager.load(context);
          print('✅ Roadmap parsed successfully (${testLoad.length} milestones found).');
        } catch (_) {
          print('⚠️  ${"Syntax error detected.".red} Please fix the errors to view your tree using "vcs roadmap".');
        }
        return;

      case 'add':
        if (args.length < 3) {
          print('❌ Usage: vcs roadmap add <version> "<title>"');
          return;
        }
        roadmap.add(Milestone(version: args[1], title: args[2], tasks: []));
        print('🚀 Milestone ${args[1].bold} added.');
        break;

      case 'task':
        if (args.length < 3) {
          print('❌ Usage: vcs roadmap task <version> "<description>" [-g TAG]');
          return;
        }
        final version = args[1];
        final description = args[2];
        
        final finalTag = (taskTag ?? 'TASK').toUpperCase();

        try {
          final ms = roadmap.firstWhere((e) => e.version == version);
          final id = 'TSK-${(ms.tasks.length + 1).toString().padLeft(3, '0')}';
          
          ms.tasks.add(RoadmapTask(id: id, tag: finalTag, description: description));
          print('✅ Task ${id.cyan} <$finalTag> created under ${version.bold}.');
        } catch (_) {
          print('❌ Error: Milestone version "$version" not found in roadmap.');
          return;
        }
        break;

      case 'done':
        if (args.length < 2) {
          print('❌ Usage: vcs roadmap done <task-id>');
          return;
        }
        final targetId = args[1].toUpperCase();
        bool found = false;

        for (var ms in roadmap) {
          for (var task in ms.tasks) {
            if (task.id == targetId) {
              task.isDone = !task.isDone;
              print('${task.isDone ? "✔️".green : "⭕".yellow} Task ${task.id} set to ${task.isDone ? "DONE" : "TODO"}.');
              found = true;
            }
          }
        }
        if (!found) {
          print('❌ Task $targetId not found.');
          return;
        }
        break;

      case 'rm':
        if (args.length < 2) {
          print('❌ Usage: vcs roadmap rm <version>');
          return;
        }
        roadmap.removeWhere((e) => e.version == args[1]);
        print('🗑️ Milestone ${args[1]} removed.');
        break;

      default:
        print('❌ Unknown roadmap action. Available: init, edit, add, task, done, rm');
        return;
    }

    RoadmapManager.save(context, roadmap);
  }

  static Future<void> _openSystemEditor(String filePath) async {
    final absolutePath = p.normalize(File(filePath).absolute.path);

    if (Platform.isWindows) {
      try {
        final result = await Process.run('code', [absolutePath], runInShell: true);
        if (result.exitCode != 0) throw Exception();
      } catch (e) {
        await Process.run('notepad.exe', [absolutePath]);
      }
    } else if (Platform.isMacOS) {
      await Process.run('open', [absolutePath]);
    } else {
      try {
        await Process.run('xdg-open', [absolutePath]);
      } catch (_) {
        await Process.start('nano', [absolutePath], mode: ProcessStartMode.inheritStdio);
      }
    }
  }

  static void _displayRoadmap(dynamic context) {
    final roadmap = RoadmapManager.load(context);
    if (roadmap.isEmpty) {
      print('📭 No roadmap found. Use "vcs roadmap init" to start.');
      return;
    }

    print('\n 🗺️  ${"PROJECT STRATEGIC ROADMAP".bold.underline}\n');
    
    for (var ms in roadmap) {
      print(' 📦 Version ${ms.version.green.bold} - ${ms.title.white}');
      
      if (ms.tasks.isEmpty) {
        print('    ${"No tasks planned yet.".grey}');
      }

      for (var i = 0; i < ms.tasks.length; i++) {
        final t = ms.tasks[i];
        final isLast = i == ms.tasks.length - 1;
        final branch = isLast ? ' └──' : ' ├──';
        final status = t.isDone ? ' [DONE]'.green : ' [TODO]'.yellow;
        
        print('$branch [${t.id.cyan}] <${t.tag.magenta}> ${t.description}$status');
      }
      print(''); 
    }
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
  String get gray    => '\x1B[90m$this\x1B[0m';
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
  allLanguages.forEach((label, builtin) {
    highlight.registerLanguage(label, builtin);
  });
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
    ..addCommand('inspect', ArgParser())
    ..addCommand('status', ArgParser()
      ..addFlag('ignored', abbr: 'i', help: 'List all files currently bypassed by active exclusion structures.', negatable: false)
    )
    ..addCommand('export', ArgParser()
      ..addOption('to', abbr: 'o', help: 'The destination path for the exported .zip file.')
      ..addOption('id', abbr: 'i', help: 'The specific snapshot ID to export. Defaults to latest.')
    )
    ..addCommand('import', ArgParser()
      ..addOption('from', abbr: 'f', help: 'Path to the .zip file.')
      ..addOption('track', abbr: 't', help: 'Target track for import. Defaults to active track.')
    )
    ..addCommand('clean', ArgParser()
      ..addFlag('all', help: 'Force remove all temporary sandboxes.')
    )
    ..addCommand('update')
    ..addCommand('changelog', ArgParser()..addFlag('list', abbr: 'l', negatable: false))
    ..addCommand('storage-check', ArgParser()
      ..addFlag('full', negatable: false, help: 'Perform a more intensive read check')
    )
    ..addCommand('roadmap', ArgParser()
      ..addOption('task-tag', abbr: 'g', help: 'Set tag for task insertion (e.g. CORE, PERF)')
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
    ..addCommand('open', ArgParser())
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
    ..addCommand('doctor', ArgParser()
      ..addFlag('rebuild', abbr: 'r', negatable: false, help: 'Physically scan the .vcs files to reconstruct the meta.json if it is lost.',)
      ..addFlag('reindex', abbr: 'i', negatable: false, help: 'Retroactively regenerate missing Fast-Diff indices for legacy snapshots.',
    )
    )
    ..addCommand('stats', ArgParser()
      ..addFlag('charts', abbr: 'c', help: 'Show file distribution charts.', negatable: false)
    )
    ..addCommand('summary', ArgParser()
      ..addOption('track', abbr: 't', help: 'Get summary from a specific track')
      ..addFlag('copy', abbr: 'c', negatable: false, help: 'Copy to clipboard (if supported)')
    )
    ..addCommand('help')
    ..addCommand('clear-history')
    ..addCommand('purge')
    ..addCommand('verify', ArgParser()
      ..addFlag('all', negatable: false, help: 'Verify all snapshots in the repository.')
      ..addFlag('deep', abbr: 'd', negatable: false, help: 'Deep check: compare live files vs delta-index.')
    )
    ..addCommand('bind')
    ..addCommand('diff', ArgParser(allowTrailingOptions: true)
      ..addFlag('fast', abbr: 'f', negatable: false, help: 'Quick comparison using metadata index.')
      ..addFlag('sandbox', negatable: false, help: 'Extract snapshots to temporary folders for manual audit.')
    )
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
      ..addCommand('create', ArgParser()
        ..addOption('from', abbr: 'f', help: 'Snapshot ID to branch from'))
      ..addCommand('switch')
      ..addCommand('delete'),
    )
    ..addCommand('merge-check', ArgParser()
        ..addOption('password', abbr: 'p', help: 'Repository password')
    )
    ..addCommand('merge-apply', ArgParser()
      ..addOption('password', abbr: 'p', help: 'Repository password')
      ..addOption('id', abbr: 'i', help: 'Manually specify ancestor snapshot ID for merge')
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
      ..addOption('file', abbr: 'f', help: 'Search for specific filenames or filter content search by file')
      ..addFlag('case-sensitive', abbr: 's', negatable: false, help: 'Perform a case-sensitive search')
    )
    ..addCommand('timeline', ArgParser()
      ..addOption('track', abbr: 't', help: 'Track to visualize')
      ..addOption('limit', abbr: 'n', help: 'Number of snapshots to show', defaultsTo: '15')
    )
    ..addCommand('benchmark', ArgParser()
      ..addFlag('intensive', abbr: 'i', negatable: false, help: 'Run a longer stress test')
    )
    ..addCommand('ancestry', ArgParser()
      ..addOption('track', abbr: 't', help: 'Track to inspect (defaults to active track)')
    )
    ..addCommand('hook', ArgParser()
      ..addOption('config', abbr: 'c', help: 'Set hook mode: auto or man')
    )
    ..addCommand('di', ArgParser()
      ..addOption('id', abbr: 'i', help: 'Target snapshot ID to analyze')
      ..addOption('ext', abbr: 'e', help: 'Filter files by type (e.g., `vcs di --ext .dart`).')
      ..addOption('track', abbr: 't', help: 'Target track')
    )
    ..addCommand('release', ArgParser()
      ..addCommand('create')
      ..addCommand('public')
      ..addCommand('delete')
      ..addCommand('list')
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
      case 'update': await app.update(); break;
      case 'version': app.showVersion(); break;
      case 'ui': await app.launchUI(); break;
      case 'list': await app.listRepos(); break;
      case 'clear-history': await app.clearHistory(); break;
      case 'purge': await app.purge(); break;
      case 'storage-check': await app.checkStorageHealth(); break;
      case 'benchmark': await app.runBenchmark(); break;

      case 'export':
        final outputPath = command!['to']?.toString();
        final snapshotId = command['id']?.toString() ?? 'latest';

        if (outputPath == null) {
          print('❌ Usage: vcs export --to <path/to/file.zip> [--id <snapshot_id>]');
        } else {
          await app.export(snapshotId, outputPath);
        }
        break;

      case 'import':
        final fromPath = command!['from'];
        final targetTrack = command['track'] ?? 'main';

        if (fromPath == null) {
          print('❌ Usage: vcs import --from <path/to/file.zip> [--track <name>]');
        } else {
          await app.import(fromPath, targetTrack);
        }
        break;

      case 'inspect':
        final String? snapshotId = args.length > 1 ? args[1] : null;
        await app.inspect(snapshotId);
        break;

      case 'clean':
        final context = await app.loadRepoContext();
        final List<String> pathsToClean = [];
        
        if (context != null) {
          pathsToClean.add(context.remoteRepoDir.path);
        }
        
        if (app._localMetaDir.existsSync()) {
          pathsToClean.add(app._localMetaDir.path);
        }

        if (pathsToClean.isEmpty) {
          print('⚠️ No repository context or local metadata found to clean.'.yellow);
          break;
        }

        print('🧹 Starting cleanup service...'.cyan);
        await CleanupService.removeAllSandboxes(extraPaths: pathsToClean);
        break;

      case 'release':
        final subCommand = command?.command?.name;
        if (subCommand == null) {
          print('❌ Usage: vcs release <create|public|delete|list>');
          break;
        }

        final subResult = command!.command!;
        switch (subCommand) {
          case 'create':
            if (subResult.rest.isEmpty) {
              print('❌ Please provide a message for the release.');
            } else {
              await app.createRelease(subResult.rest.join(' '));
            }
            break;

          case 'public':
            if (subResult.rest.isEmpty) {
              print('❌ Please provide the release ID to open.');
            } else {
              await app.releasePublic(subResult.rest.first);
            }
            break;

          case 'delete':
            if (subResult.rest.isEmpty) {
              print('❌ Please provide the release ID to delete.');
            } else {
              await app.deleteRelease(subResult.rest.first);
            }
            break;

          case 'list':
            await app.listReleases();
            break;
        }
        break;

      case 'status':
        final statusCommand = result.command;        
        final isIgnoredActive = statusCommand != null && statusCommand['ignored'] == true;
        await app.status(showIgnored: isIgnoredActive); 
        break;

      case 'roadmap':
        if (context == null) {
          print('❌ ${"Error:".red} USB storage context not found. Cannot manage roadmap.');
          return;
        }
        final List<String> roadmapArgs = [...command!.rest];
        
        String? explicitTag;
        if (command.options.contains('task-tag') && command['task-tag'] != null) {
          explicitTag = command['task-tag'].toString();
        }

        await RoadmapCommand.handle(roadmapArgs, context, taskTag: explicitTag);
        break;

      case 'open':
        final String? repoName = command?.rest.isNotEmpty == true ? command?.rest.first : null;
        await app.openTarget(repoName);
        break;

      case 'stats':
        final statsOptions = command != null ? { for (var key in command.options) key : command[key] } : null;        
        await app.stats(
          command: statsOptions, 
          args: args
        );
        break;

      case 'hook':
        if (context == null) {
          print('❌ ${"Error:".red} USB storage context not found. Cannot manage hooks.');
          return;
        }
        List<String> hookArgs = [...command!.rest];
        if (command.options.contains('config') && command['config'] != null) {
          hookArgs.addAll(['-c', command['config']]);
        }

        if (hookArgs.isEmpty) {
          print('❌ Usage: vcs hook <create|edit|exec> <name> [-c auto|man]');
        } else {
          await HookManager.handleCommand(hookArgs, context);
        }
        break;

      case 'merge-check':
        final targetTrack = result.command?.rest.firstOrNull;
        if (targetTrack == null) {
          print('❌ ${"Missing track name.".red} Usage: vcs merge-check <track-name>');
          return;
        }
        
        final pass = result.command?['password'];
        await app.mergeCheck(targetTrack, password: pass);
        break;

      case 'merge-apply':
        final targetTrack = result.command?.rest.firstOrNull;
        if (targetTrack == null) {
          print('❌ ${"Missing track name.".red} Usage: vcs merge-apply <track-name> [--id <snapshot-id>]');
          return;
        }
        
        final pass = result.command?['password'];
        final manualId = result.command?['id'];
        
        await app.mergeApply(
          targetTrack, 
          password: pass, 
          manualBaseId: manualId
        );
        break;

      case 'doctor':
        final rebuild = result.command?['rebuild'] == true;
        final reindex = result.command?['reindex'] == true;
        
        await app.doctor(
          rebuildMode: rebuild, 
          reindexMode: reindex,
        );
        break;

      case 'changelog':
        final isList = command?['list'] == true;
        app.showChangelog(interactive: isList);
        break;

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

      case 'ancestry':
        final track = result.command?['track'] as String?;
        await app.showAncestry(track: track);
        break;

      case 'info':
        await app.info(showCharts: command!['charts'] == true);
        break;

      case 'bind':
        final repoId = command!.rest.isNotEmpty ? command.rest.first : null;
        await app.bindRepo(repoId: repoId);
        break;

      case 'diff':
        await app.diff(command?.arguments ?? []);
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
            deep: command['deep'] == true,
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
              if (sub.rest.isEmpty) {
                print('❌ Track name required.');
              } else {
                final trackName = sub.rest.first;
                final fromSnapshot = sub['from'] as String?; 
                
                await app.trackCreate(trackName, fromSnapshot: fromSnapshot); 
              }
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
        if (command!.rest.isEmpty && command['file'] == null) {
          print('\n❌ Usage: vcs search <query> [options]');
          print('   Or search by file only: vcs search --file <name>');
          return;
        }
        
        await app.search(
          command.rest.join(' '),
          track: command['track'],
          caseSensitive: command['case-sensitive'] == true,
          snapshotId: command['id'],
          limit: int.tryParse(command['max']?.toString() ?? ''),
          fileQuery: command['file'],
        );
        break;

      case 'di':
        if (context == null) {
          print('❌ ${"Error:".red} Repository context not found.');
          return;
        }

        final meta = context.remoteMeta;
        
        final targetTrackName = command?['track']?.toString() ?? meta.activeTrack;
        final String? extensionFilter = command?['ext']?.toString();
        
        final trackState = meta.tracks[targetTrackName];

        if (trackState == null) {
          print('❌ ${"Error:".red} Track "${targetTrackName.cyan}" not found in metadata.');
          return;
        }

        String? targetId = command?['id']?.toString();
        
        if (targetId == null && trackState.logs.isNotEmpty) {
          targetId = trackState.logs.last.id;
        }

        if (targetId == null) {
          print('❌ ${"Error:".red} No snapshots found in track: ${targetTrackName.cyan}');
          return;
        }

        try {
          final report = await IndexService.generateDeltaReport(
            remoteRepoDir: context.remoteRepoDir,
            currentId: targetId,
            extensionFilter: extensionFilter,
          );
          print(app._renderMarkdown(report));
          
        } catch (e) {
          print('❌ ${"Error generating report:".red} $e');
        }
        break;

      default:
        app.showHelp();
    }
  } catch (e) {
    print('❌ Error: $e');
  }
}
