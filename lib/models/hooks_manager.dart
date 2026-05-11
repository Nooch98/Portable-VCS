import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:vcs/vcs.dart';

class HookManager {
  static Future<void> handleCommand(List<String> args, dynamic context) async {
    if (context == null) return;
    
    if (args.length < 2) {
      print('Usage: vcs hook <create|edit|exec> <name> [-c auto|man]');
      return;
    }

    final String action = args[0].toLowerCase();
    final String hookName = args[1];
    
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

    switch (action) {
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
        await _executeHook(scriptFile, isManual: true);
        break;
    }
  }

  static Future<bool> runAutoHooks(dynamic context) async {
    if (context == null) return true;

    final String hooksPath = p.join(context.remoteRepoDir.path, 'hooks');
    final configFile = File(p.join(hooksPath, 'hooks.json'));
    
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
          
          final success = await _executeHook(scriptFile, isManual: false);
          if (!success) {
            print('❌ ${"Push aborted:".red} Hook "$name" failed.');
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

  static Future<bool> _executeHook(File script, {required bool isManual}) async {
    final absolutePath = p.normalize(script.absolute.path);
    
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

    final result = await Process.run(executable, procArgs, runInShell: true);

    if (result.stdout.toString().trim().isNotEmpty) print(result.stdout);
    if (result.stderr.toString().trim().isNotEmpty) {
      print('❌ Hook Error Output:');
      print(result.stderr);
    }

    if (result.exitCode == 0) {
      if (isManual) print('✅ Success.');
      return true;
    } else {
      print('⚠️ Hook failed (Exit: ${result.exitCode})');
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
