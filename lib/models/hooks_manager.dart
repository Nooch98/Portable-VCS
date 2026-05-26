import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:vcs/vcs.dart';

class HookManager {
  static Future<void> handleCommand(List<String> args, dynamic context) async {
    if (context == null) return;
    
    if (args.isEmpty) {
      print('Usage: vcs hook <create|edit|exec|list|delete> [name] [-c auto|man]');
      return;
    }

    final String action = args[0].toLowerCase();

    if (action != 'list' && args.length < 2) {
      print('❌ Error: Missing hook name. Usage: vcs hook $action <name>');
      return;
    }

    final String hookName = args.length > 1 ? args[1] : '';
    
    String mode = 'man';
    int configIdx = args.indexWhere((arg) => arg == '-c' || arg == '--config');
    if (configIdx != -1 && configIdx + 1 < args.length) {
      mode = (args[configIdx + 1].toLowerCase() == 'auto') ? 'auto' : 'man';
    }

    final String hooksPath = p.join(context.remoteRepoDir.path, 'hooks');
    final hooksDir = Directory(hooksPath);

    if (!hooksDir.existsSync()) hooksDir.createSync(recursive: true);

    final configFile = File(p.join(hooksPath, 'hooks.json'));
    final ext = Platform.isWindows ? '.ps1' : '.sh';
    final scriptFile = File(p.join(hooksPath, '$hookName$ext'));

    Map<String, dynamic> configMap = {};
    if (configFile.existsSync()) {
      try {
        configMap = jsonDecode(configFile.readAsStringSync());
      } catch (_) {}
    }

    final String execId = 'MANUAL-${DateTime.now().millisecondsSinceEpoch}';
    final meta = context.remoteMeta;
    final lastAuthor = meta.logs.isNotEmpty ? meta.logs.first.author : 'unknown';

    switch (action) {
      case 'list':
        print('\n📋 ${"Configured Hooks:".bold}\n');
        if (configMap.isEmpty) {
          print('   ${"No hooks configured.".italic}');
        } else {
          for (final entry in configMap.entries) {
            final name = entry.key;
            final mode = entry.value['mode'] ?? 'man';
            final scriptFile = _findExistingScript(hooksPath, name);
            final exists = scriptFile.existsSync();
            
            final statusIcon = exists ? '✅' : '❌';
            final modeColor = mode == 'auto' ? '\x1B[32m$mode\x1B[0m' : '\x1B[33m$mode\x1B[0m';
            
            print('   $statusIcon ${name.padRight(15)} [Mode: $modeColor]');
          }
        }
        print('');
        break;
      case 'create':
      case 'edit':
        configMap[hookName] = {'mode': mode};
        configFile.writeAsStringSync(JsonEncoder.withIndent('  ').convert(configMap));

        if (action == 'create' && !scriptFile.existsSync()) {
          final template = Platform.isWindows 
              ? '# PowerShell Hook\nWrite-Host "Running $hookName..."\n' 
              : '#!/bin/bash\necho "Running $hookName..."\n';
          scriptFile.writeAsStringSync(template);
          if (!Platform.isWindows) await Process.run('chmod', ['+x', scriptFile.path]);
        }
        
        print('✅ Hook "$hookName" set to [$mode]. Opening editor...');
        await _openSystemEditor(scriptFile.path);
        break;

      case 'exec':
        if (!scriptFile.existsSync()) {
          print('❌ Error: Script file not found: ${scriptFile.path}');
          return;
        }

        final Map<String, String> manualEnv = {
          'VCS_SNAPSHOT_ID': execId,
          'VCS_TRACK': meta.activeTrack,
          'VCS_AUTHOR': lastAuthor ?? 'unknown',
          'VCS_TIMESTAMP': DateTime.now().toIso8601String(),
          'VCS_VERSION': vcsBaseVersion,
          'VCS_REPO_ROOT': context.remoteRepoDir.path,
        };

        await _executeHook(scriptFile, isManual: true, extraEnv: manualEnv);
        break;
      case 'delete':
        if (configMap.containsKey(hookName)) {
          configMap.remove(hookName);
          configFile.writeAsStringSync(JsonEncoder.withIndent('  ').convert(configMap));
        }

        final fileToDelete = _findExistingScript(hooksPath, hookName);
        if (fileToDelete.existsSync()) {
          fileToDelete.deleteSync();
          print('✅ Hook "$hookName" deleted successfully.'.green);
        } else {
          print('⚠️ Hook "$hookName" removed from config, but no script file found.'.yellow);
        }
        break;
    }
  }

  static Future<bool> runAutoHooks(dynamic context, {Map<String, String>? extraEnv}) async {
    if (context == null) return true;

    final String hooksPath = p.join(context.remoteRepoDir.path, 'hooks');
    final configFile = File(p.join(hooksPath, 'hooks.json'));
    final String currentTrack = context.remoteMeta.activeTrack ?? 'main';
    final trackData = context.remoteMeta.tracks[currentTrack];
    final String currentId = (trackData != null && trackData.logs.isNotEmpty) 
        ? trackData.logs.first.id 
        : 'N/A';
    
    if (!configFile.existsSync()) return true;

    try {
      final Map<String, dynamic> config = jsonDecode(await configFile.readAsString());
      
      final autoHookNames = config.entries
          .where((e) => e.value['mode'] == 'auto')
          .map((e) => e.key)
          .toList();

      for (final name in autoHookNames) {
        final scriptFile = _findExistingScript(hooksPath, name);
        
        if (scriptFile.existsSync()) {
          print('🪝  ${"Executing auto hook:".cyan} ${name.bold}...');
          
          final success = await _executeHook(
            scriptFile, 
            isManual: false,
            extraEnv: extraEnv
          );
          
          if (!success) {
            print('\n❌ ${"Push aborted:".red} Hook "$name" failed.');
            return false;
          }
        }
      }
    } catch (e) {
      print('⚠️  ${"Warning:".yellow} Could not process hooks.json');
    }

    return true;
  }

  static File _findExistingScript(String hooksPath, String name) {
    final extensions = ['.ps1', '.bat', '.sh', '.cmd'];
    
    for (var ext in extensions) {
      final file = File(p.join(hooksPath, '$name$ext'));
      if (file.existsSync()) {
        return file;
      }
    }

    final defaultExt = Platform.isWindows ? '.ps1' : '.sh';
    return File(p.join(hooksPath, '$name$defaultExt'));
  }

  static Future<bool> _executeHook(File script, {
    required bool isManual,
    Map<String, String>? extraEnv
    }) async {
    final absolutePath = p.normalize(script.absolute.path);

    final Map<String, String> environment = Map.from(Platform.environment);
    if (extraEnv != null) {
      environment.addAll(extraEnv);
    }
    
    String executable;
    List<String> procArgs;

    if (Platform.isWindows) {
      executable = 'powershell.exe';
      procArgs = [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', absolutePath
      ];
    } else {
      executable = 'bash';
      procArgs = [absolutePath];
    }

    final process = await Process.start(
      executable, 
      procArgs, 
      runInShell: true, 
      mode: ProcessStartMode.inheritStdio,
      environment: environment
    );

    final exitCode = await process.exitCode;

    if (exitCode == 0) {
      if (isManual) print('\n✅ Success.');
      return true;
    } else {
      print('\n⚠️ Hook failed (Exit: $exitCode)');
      return false;
    }
  }

  static Future<void> _openSystemEditor(String filePath) async {
    final file = File(filePath);
    final absolutePath = p.normalize(file.absolute.path);

    if (!await file.exists()) {
      print('❌ VCS Error: The file does not exist at path: $absolutePath');
      return;
    }

    if (Platform.isWindows) {
      try {
        final result = await Process.run('code', [absolutePath], runInShell: true);
        
        if (result.exitCode != 0) {
          throw Exception('VS Code not found');
        }
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
}
