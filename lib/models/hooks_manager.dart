import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:vcs/utils/editor.dart';
import 'package:vcs/vcs.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

class HookManager {
  static Future<void> handleCommand(List<String> args, dynamic context) async {
    if (context == null) return;
    
    if (args.isEmpty) {
      print('Usage: vcs hook <create|edit|exec|list|delete> [name] [-c auto|man]');
      return;
    }

    final String action = args[0].toLowerCase();

    if (action != 'list' && 
        action != 'log' && 
        action != 'clean' &&
        args.length < 2) {
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
    final scriptFile = _findExistingScript(hooksPath, hookName);

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
        await _openEmbeddedEditor(scriptFile);
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
      case 'log':
        await showLogs(hooksPath, hookName.isNotEmpty ? hookName : null);
        break;
      case 'clean':
        await clearLogs(context.remoteRepoDir.path);
        break;
    }
  }

  static Future<void> _openEmbeddedEditor(File file) async {
    final completer = Completer<void>();
    Timer? heartbeatTimer;
    
    void resetHeartbeat() {
      heartbeatTimer?.cancel();
      heartbeatTimer = Timer(Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          print('\n⚠️ Editor connection lost. Shutting down server...');
          completer.complete();
        }
      });
    }

    Future<void> launchMinimal(String url) async {
      final chromiumBrowsers = Platform.isWindows 
        ? ['chrome.exe', 'msedge.exe', 'brave.exe', 'opera.exe']
        : ['google-chrome', 'microsoft-edge', 'brave-browser', 'opera'];

      for (final browser in chromiumBrowsers) {
        try {
          final result = await Process.run(browser, ['--app=$url'], runInShell: true);
          if (result.exitCode == 0) return;
        } catch (_) {}
      }

      if (Platform.isWindows) await Process.run('start', [url], runInShell: true);
      else if (Platform.isMacOS) await Process.run('open', [url]);
      else await Process.run('xdg-open', [url]);
    }

    final handler = (Request request) async {
      final path = request.url.path;
      if (path == '' || path == 'index.html') return Response.ok(EditorAssets.html, headers: {'content-type': 'text/html'});
      if (path == 'api/heartbeat') { resetHeartbeat(); return Response.ok('OK'); }
      
      if (path == 'api/get-content') {
        final String lang = file.path.endsWith('.ps1') || file.path.endsWith('.bat') ? 'powershell' : 'shell';
        return Response.ok(jsonEncode({'content': await file.readAsString(), 'language': lang}));
      }
      
      if (path == 'api/save') {
        final data = jsonDecode(await request.readAsString());
        await file.writeAsString(data['content']);
        completer.complete();
        return Response.ok('Saved');
      }
      
      if (path == 'api/test') {
        final data = jsonDecode(await request.readAsString());
        final ext = Platform.isWindows ? '.ps1' : '.sh';
        final tempFile = File(p.join(Directory.systemTemp.path, 'vcs_test_${DateTime.now().millisecondsSinceEpoch}$ext'));
        await tempFile.writeAsString(data['content']);
        
        final proc = await Process.run(
          Platform.isWindows ? 'powershell' : 'bash',
          Platform.isWindows ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', tempFile.path] : [tempFile.path]
        );
        
        if (await tempFile.exists()) await tempFile.delete();
        return Response.ok(jsonEncode({'output': proc.stdout + proc.stderr}));
      }
      return Response.notFound('Not found');
    };

    final server = await io.serve(handler, 'localhost', 8080);    
    print('\n🚀 Editor ready: http://localhost:8080');
    
    await launchMinimal('http://localhost:8080');    
    resetHeartbeat();

    await completer.future;
    heartbeatTimer?.cancel();
    await server.close();
    print('✅ Editor closed. Server stopped.');
  }

  static Future<void> clearLogs(String remoteRepoDir) async {
    final hooksPath = p.join(remoteRepoDir, 'hooks');
    final hooksDir = Directory(hooksPath);
    
    if (!hooksDir.existsSync()) return;

    final logFiles = hooksDir.listSync().where((f) => f.path.endsWith('.log'));
    
    int count = 0;
    for (final file in logFiles) {
      await file.delete();
      count++;
    }
    
    if (count > 0) {
      print('🧹 ${"Cleaned $count old hook log(s).".grey}');
    }
  }

  static Future<void> showLogs(String hooksPath, String? hookName) async {
    final hooksDir = Directory(hooksPath);
    final logFiles = hooksDir.listSync()
        .where((f) => f.path.endsWith('.log'))
        .map((f) => f as File)
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    if (logFiles.isEmpty) {
      print('ℹ️ No hook logs found.');
      return;
    }

    if (hookName != null) {
      final logFile = logFiles.firstWhere(
        (f) => p.basenameWithoutExtension(f.path) == hookName,
        orElse: () => File(''),
      );
      
      if (await logFile.exists()) {
        await _renderFormattedLog(logFile);
      } else {
        print('❌ Log for "$hookName" not found.');
      }
      return;
    }

    print('\n📋 ${"Available Hook Logs (ordered by date):".bold}');
    for (var i = 0; i < logFiles.length; i++) {
      final name = p.basenameWithoutExtension(logFiles[i].path);
      final modDate = logFiles[i].statSync().modified.toString().substring(0, 19);
      print('  ${(i + 1).toString().cyan.padRight(3)} ${name.padRight(20)} ${modDate.grey}');
    }
    
    stdout.write('\nSelect a number to view log (or enter to exit): '.blue);
    final choice = stdin.readLineSync();
    final idx = int.tryParse(choice ?? '') ?? -1;
    
    if (idx > 0 && idx <= logFiles.length) {
      await _renderFormattedLog(logFiles[idx - 1]);
    }
  }

  static Future<void> _renderFormattedLog(File logFile) async {
    final lines = await logFile.readAsLines();
    final fileName = p.basename(logFile.path);
    final fileStats = await logFile.stat();
    
    print('\n' + '═' * 60);
    print('📄 ${"HOOK LOG REPORT".bold.white}');
    print('   ${"File:".grey} $fileName');
    print('   ${"Size:".grey} ${fileStats.size} bytes');
    print('   ${"Modified:".grey} ${fileStats.modified}');
    print('═' * 60);

    for (var line in lines) {
      final l = line.trim();
      
      if (l.contains('[STDERR]') || 
          l.toLowerCase().contains('error:') || 
          l.toLowerCase().contains('failed') || 
          l.toLowerCase().contains('exception')) {
        print('  ${'!!'.red.bold} ${l.replaceAll('[STDERR]', '').trim().red}');
      } 
      else if (l.contains('[STDOUT]')) {
        print('  ${'>>'.cyan} ${l.replaceAll('[STDOUT]', '').trim().white}');
      } 
      else if (l.contains('---')) {
        print('\n  ${l.yellow.bold}');
      } 
      else {
        print('    ${l.grey}');
      }
    }
    print('═' * 60 + '\n');
  }

  static Future<bool> runAutoHooks(dynamic context, {Map<String, String>? extraEnv}) async {
    if (context == null) return true;

    final String hooksPath = p.join(context.remoteRepoDir.path, 'hooks');
    final configFile = File(p.join(hooksPath, 'hooks.json'));
    final String currentTrack = context.remoteMeta.activeTrack ?? 'main';
    final trackData = context.remoteMeta.tracks[currentTrack];
    
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
    final logFile = File(script.path.replaceAll(RegExp(r'\.(ps1|sh|bat|cmd)$'), '.log'));
    final IOSink logSink = logFile.openWrite();

    logSink.writeln('--- Hook Execution: ${DateTime.now()} ---');

    final Map<String, String> environment = Map.from(Platform.environment);
    if (extraEnv != null) {
      environment.addAll(extraEnv);
    }
    
    String executable;
    List<String> procArgs;

    if (Platform.isWindows) {
      executable = 'powershell.exe';
      procArgs = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', absolutePath];
    } else {
      executable = 'bash';
      procArgs = [absolutePath];
    }

    final process = await Process.start(
      executable, 
      procArgs, 
      runInShell: true, 
      mode: ProcessStartMode.normal,
      environment: environment
    );

    void handleOutput(String line, {bool isError = false}) {
      if (isError) {
        stderr.write(line);
        logSink.writeln('[STDERR] $line');
      } else {
        stdout.write(line);
        logSink.writeln('[STDOUT] $line');
      }
    }

    process.stdout.transform(utf8.decoder).listen((data) => handleOutput(data, isError: false));
    process.stderr.transform(utf8.decoder).listen((data) => handleOutput(data, isError: true));

    final exitCode = await process.exitCode;
    
    logSink.writeln('--- Exit Code: $exitCode ---');
    await logSink.close(); 

    if (exitCode == 0) {
      if (isManual) print('\n✅ Success.');
      return true;
    } else {
      print('\n⚠️ Hook failed (Exit: $exitCode). Check log: ${p.basename(logFile.path)}');
      return false;
    }
  }
}
