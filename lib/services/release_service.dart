import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart' as crypto_alg;
import 'package:path/path.dart' as p;
import 'package:vcs/models/release_meta.dart';
import 'package:vcs/vcs.dart';

class ReleaseService {
  final Directory repoDir;
  late Directory releasesDir;

  ReleaseService(this.repoDir) {
    releasesDir = Directory(p.join(repoDir.path, 'releases'));
  }

  Future<void> ensureInitialized() async {
    if (!await releasesDir.exists()) {
      await releasesDir.create(recursive: true);
    }

    final indexFile = File(p.join(releasesDir.path, 'releases.json'));
    if (!await indexFile.exists()) {
      await indexFile.writeAsString(jsonEncode({
        'lastUpdated': DateTime.now().toIso8601String(),
        'releases': []
      }));
    }
  }

  Future<Uint8List> _decryptSnapshot(Uint8List encryptedContent, String password) async {
    final contentString = utf8.decode(encryptedContent);
    final parts = contentString.split("\n---VCS_DATA_START---\n");
    final wrapper = jsonDecode(parts[1]);

    final salt = base64Decode(wrapper['salt_b64']);
    final nonce = base64Decode(wrapper['nonce_b64']);
    final cipherText = base64Decode(wrapper['cipher_b64']);
    final mac = base64Decode(wrapper['mac_b64']);

    final algorithm = crypto_alg.Pbkdf2(
      macAlgorithm: crypto_alg.Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    );
    final secretKey = await algorithm.deriveKeyFromPassword(password: password, nonce: salt);

    final aes = crypto_alg.AesGcm.with256bits();
    final secretBox = crypto_alg.SecretBox(
      cipherText,
      nonce: nonce,
      mac: crypto_alg.Mac(mac),
    );
    
    final decryptedBytes = await aes.decrypt(secretBox, secretKey: secretKey);
    
    final payload = jsonDecode(utf8.decode(decryptedBytes));
    return base64Decode(payload['zip_base64']);
  }

  Future<void> appendReleaseToIndex(ReleaseEntry entry) async {
    await ensureInitialized();
    
    final indexFile = File(p.join(releasesDir.path, 'releases.json'));
    final content = await indexFile.readAsString();
    final data = jsonDecode(content);
    
    if (data['releases'] == null) data['releases'] = [];
    
    (data['releases'] as List).add(entry.toJson());
    data['lastUpdated'] = DateTime.now().toIso8601String();
    
    await indexFile.writeAsString(jsonEncode(data));
  }
  
  Future<void> deleteRelease(String releaseId) async {
    final indexFile = File(p.join(releasesDir.path, 'releases.json'));
    if (!await indexFile.exists()) return;

    final content = await indexFile.readAsString();
    final data = jsonDecode(content);
    final List releases = data['releases'];

    final releaseToRemove = releases.firstWhere(
      (r) => r['releaseId'] == releaseId,
      orElse: () => null,
    );

    if (releaseToRemove == null) {
      print('❌ ${"Release $releaseId not found in index.".red}');
      return;
    }

    releases.remove(releaseToRemove);
    data['lastUpdated'] = DateTime.now().toIso8601String();
    await indexFile.writeAsString(jsonEncode(data));

    final releaseFolder = Directory(p.join(releasesDir.path, releaseId));
    if (await releaseFolder.exists()) {
      await releaseFolder.delete(recursive: true);
      print('🗑️  ${"Release $releaseId and its files have been deleted.".green}');
    }
  }

  Future<void> listReleases() async {
    final indexFile = File(p.join(releasesDir.path, 'releases.json'));
    if (!await indexFile.exists()) {
      print('ℹ️  ${"No releases found.".grey}');
      return;
    }

    final content = await indexFile.readAsString();
    final data = jsonDecode(content);
    final List releases = data['releases'];

    if (releases.isEmpty) {
      print('ℹ️  ${"No releases registered in this repository.".grey}');
    } else {
      print('\n🚀 ${"REGISTERED RELEASES:".bold.cyan}');
      print('----------------------------------------------------');
      for (var r in releases) {
        final date = DateTime.fromMillisecondsSinceEpoch(r['timestamp']);
        print('${r['version'].toString().green.bold} | ID: ${r['releaseId'].toString().yellow}');
        print('   Message: ${r['message']}');
        print('   Date: ${date.toString().grey}\n');
      }
    }
  }

  Future<void> releasePublic(String releaseId, String password) async {
    final releaseFolder = Directory(p.join(releasesDir.path, releaseId));
    final archiveFile = File(p.join(releaseFolder.path, 'archive.enc'));

    if (!await archiveFile.exists()) {
      print('❌ ${"Release archive not found!".red}');
      return;
    }

    print('🔓 Decrypting release $releaseId...');
    
    final encryptedBytes = await archiveFile.readAsBytes();
    final decryptedData = await _decryptSnapshot(encryptedBytes, password); 

    final tempSystemDir = Directory(p.join(Directory.systemTemp.path, 'vcs_workspaces'));
    final workspaceDir = Directory(p.join(tempSystemDir.path, 'rel_$releaseId'));

    if (await workspaceDir.exists()) await workspaceDir.delete(recursive: true);
    await workspaceDir.create(recursive: true);

    final archive = ZipDecoder().decodeBytes(decryptedData);
    for (final file in archive) {
      if (file.isFile) {
        final data = file.content as List<int>;
        final outFile = File(p.join(workspaceDir.path, file.name));
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(data);
      }
    }

    print('✨ ${"Launching isolated VS Code instance...".green}');
    if (Platform.isWindows) {
      await Process.run('code.cmd', ['--new-window', workspaceDir.path]);
    } else {
      await Process.run('code', ['--new-window', workspaceDir.path]);
    }
  }
}
