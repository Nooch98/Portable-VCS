import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class AliasManager {
  final Directory remoteRepoDir;

  AliasManager(this.remoteRepoDir);

  File get _aliasFile {
    return File(p.join(remoteRepoDir.parent.path, 'vcs_aliases.json'));
  }

  Future<Map<String, String>> loadAliases() async {
    try {
      if (!await _aliasFile.exists()) return {};
      final content = await _aliasFile.readAsString();
      return Map<String, String>.from(jsonDecode(content));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveAlias(String name, String command) async {
    final aliases = await loadAliases();
    aliases[name] = command;
    await _aliasFile.writeAsString(jsonEncode(aliases), flush: true);
  }

  Future<void> removeAlias(String name) async {
    final aliases = await loadAliases();
    if (aliases.containsKey(name)) {
      aliases.remove(name);
      await _aliasFile.writeAsString(jsonEncode(aliases), flush: true);
    }
  }
}
