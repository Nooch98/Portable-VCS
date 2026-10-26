import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class GitHubFileChange {
  final String path;
  final String status;
  final int sizeBytes;

  GitHubFileChange({
    required this.path,
    required this.status,
    required this.sizeBytes,
  });
}

class GitHubPreviewResult {
  final String owner;
  final String repo;
  final String branch;
  final String? currentHeadSha;
  final List<GitHubFileChange> changes;
  final Map<String, File> localFilesToUpload;
  final Map<String, String> remoteFiles;

  GitHubPreviewResult({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.currentHeadSha,
    required this.changes,
    required this.localFilesToUpload,
    required this.remoteFiles,
  });
}

class GitHubSyncService {
  static const String _baseUrl = 'https://api.github.com';

  static Future<GitHubPreviewResult> previewPush({
    required String repoOwnerAndName,
    required String branch,
    required String token,
    required Directory projectDir,
  }) async {
    final parts = repoOwnerAndName.split('/');
    if (parts.length != 2) {
      throw Exception('Invalid repository format. Use "owner/repo" (e.g., Nooch98/vcs)');
    }
    final owner = parts[0];
    final repo = parts[1];

    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'VCS-Portable-Vault',
    };

    print('🔍 Checking remote status on GitHub ($owner/$repo@$branch)...');
    String? headTreeSha;
    String? currentHeadSha;

    final refResponse = await http.get(
      Uri.parse('$_baseUrl/repos/$owner/$repo/git/ref/heads/$branch'),
      headers: headers,
    );

    if (refResponse.statusCode == 200) {
      final refData = jsonDecode(refResponse.body);
      currentHeadSha = refData['object']['sha'];

      final commitResponse = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/commits/$currentHeadSha'),
        headers: headers,
      );
      if (commitResponse.statusCode == 200) {
        headTreeSha = jsonDecode(commitResponse.body)['tree']['sha'];
      }
    } else if (refResponse.statusCode == 404) {
      print('⚠️ Branch "$branch" or repository does not have this branch yet. It will be created.');
    } else {
      throw Exception('Failed to connect to GitHub API: ${refResponse.statusCode}\n${refResponse.body}');
    }

    final Map<String, String> remoteFiles = {};
    final Map<String, String> remoteFilesByLower = {};
    final Map<String, String> lowerToOriginalRemotePath = {};
    final Map<String, int> remoteFileSizes = {};

    if (headTreeSha != null) {
      final treeResponse = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/trees/$headTreeSha?recursive=1'),
        headers: headers,
      );
      if (treeResponse.statusCode == 200) {
        final treeData = jsonDecode(treeResponse.body);
        for (var item in (treeData['tree'] as List)) {
          if (item['type'] == 'blob') {
            final remotePath = (item['path'] as String).replaceAll('\\', '/').trim();
            final sha = item['sha'] as String;
            final size = item['size'] as int? ?? 0;

            remoteFiles[remotePath] = sha;
            remoteFilesByLower[remotePath.toLowerCase()] = sha;
            lowerToOriginalRemotePath[remotePath.toLowerCase()] = remotePath;
            remoteFileSizes[remotePath.toLowerCase()] = size;
          }
        }
      }
    }

    final ignoreFile = File(p.join(projectDir.path, '.gitignore'));
    List<String> ignorePatterns = ['.vcs/', '.git/', '.vcs_dots/'];
    if (await ignoreFile.exists()) {
      final lines = await ignoreFile.readAsLines();
      ignorePatterns.addAll(
        lines.map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#'))
      );
    }

    bool isIgnored(String relativePath) {
      final path = relativePath.replaceAll('\\', '/');
      if (path.startsWith('.vcs') || path.startsWith('.git') || path.startsWith('.vcs_dots')) {
        return true;
      }

      for (var pattern in ignorePatterns) {
        String cleanPattern = pattern.replaceAll(RegExp(r'^/'), '');

        if (cleanPattern.endsWith('/')) {
          final dirName = cleanPattern.substring(0, cleanPattern.length - 1);
          if (path == dirName || path.startsWith('$dirName/')) {
            return true;
          }
        } else {
          if (path == cleanPattern || path.endsWith('/$cleanPattern') || path.startsWith('$cleanPattern/')) {
            return true;
          }
          if (cleanPattern.startsWith('*')) {
            final ext = cleanPattern.substring(1);
            if (path.endsWith(ext)) return true;
          }
        }
      }
      return false;
    }

    final List<GitHubFileChange> changes = [];
    final Map<String, File> filesToUpload = {};

    await for (var entity in projectDir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final relativePath = p.relative(entity.path, from: projectDir.path);
        
        if (isIgnored(relativePath)) {
          continue;
        }

        final normalizedPath = relativePath.replaceAll('\\', '/').trim();
        final lowerPath = normalizedPath.toLowerCase();
        final targetPath = lowerToOriginalRemotePath[lowerPath] ?? normalizedPath;

        final stat = await entity.stat();
        final localSize = stat.size;
        final remoteSha = remoteFilesByLower[lowerPath];
        final remoteSize = remoteFileSizes[lowerPath];

        if (remoteSha == null) {
          changes.add(GitHubFileChange(path: targetPath, status: 'added', sizeBytes: localSize));
          filesToUpload[targetPath] = entity;
        } else if (remoteSize != null && remoteSize != localSize) {
          changes.add(GitHubFileChange(path: targetPath, status: 'modified', sizeBytes: localSize));
          filesToUpload[targetPath] = entity;
        }
      }
    }

    return GitHubPreviewResult(
      owner: owner,
      repo: repo,
      branch: branch,
      currentHeadSha: currentHeadSha,
      changes: changes,
      localFilesToUpload: filesToUpload,
      remoteFiles: remoteFiles,
    );
  }

  static Future<void> executePush({
    required GitHubPreviewResult preview,
    required String token,
    required String message,
    required String authorName,
  }) async {
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'VCS-Portable-Vault',
    };

    final totalFilesToUpload = preview.localFilesToUpload.length;

    if (totalFilesToUpload == 0 && preview.changes.isEmpty) {
      print('ℹ️ No changes detected to push.');
      return;
    }

    final Map<String, String> treeEntries = Map.from(preview.remoteFiles);

    if (totalFilesToUpload > 0) {
      print('🚀 [1/4] Uploading modified/new file blobs to GitHub (0/$totalFilesToUpload)...');
      int currentIndex = 0;
      
      for (var entry in preview.localFilesToUpload.entries) {
        currentIndex++;
        final path = entry.key;
        final file = entry.value;
        
        stdout.write('   [$currentIndex/$totalFilesToUpload] Uploading: $path ... ');

        try {
          final bytes = await file.readAsBytes();
          final base64Content = base64Encode(bytes);

          final blobResponse = await http.post(
            Uri.parse('$_baseUrl/repos/${preview.owner}/${preview.repo}/git/blobs'),
            headers: headers,
            body: jsonEncode({
              'content': base64Content,
              'encoding': 'base64',
            }),
          );

          if (blobResponse.statusCode != 201) {
            print('❌ Error');
            throw Exception('Failed to create blob for $path (${blobResponse.statusCode}): ${blobResponse.body}');
          }

          final blobSha = jsonDecode(blobResponse.body)['sha'];
          treeEntries[path] = blobSha;
          print('✅ OK (${bytes.length} bytes)');
        } catch (e) {
          print('❌ Error');
          rethrow;
        }
      }
    } else {
      print('🚀 [1/4] No new or modified blobs to upload. Reusing existing remote tree state.');
    }

    for (var change in preview.changes) {
      if (change.status == 'deleted') {
        treeEntries.remove(change.path);
      }
    }

    print('\n🌳 [2/4] Constructing Git Tree structure...');
    final List<Map<String, dynamic>> treePayload = [];
    
    treeEntries.forEach((path, sha) {
      treePayload.add({
        'path': path,
        'mode': '100644',
        'type': 'blob',
        'sha': sha,
      });
    });

    final treeResponse = await http.post(
      Uri.parse('$_baseUrl/repos/${preview.owner}/${preview.repo}/git/trees'),
      headers: headers,
      body: jsonEncode({
        'base_tree': preview.currentHeadSha,
        'tree': treePayload,
      }),
    );

    if (treeResponse.statusCode != 201) {
      throw Exception('Failed to create tree: ${treeResponse.body}');
    }
    final newTreeSha = jsonDecode(treeResponse.body)['sha'];

    print('📦 [3/4] Creating commit object...');
    final List<String> parents = preview.currentHeadSha != null ? [preview.currentHeadSha!] : [];

    final commitResponse = await http.post(
      Uri.parse('$_baseUrl/repos/${preview.owner}/${preview.repo}/git/commits'),
      headers: headers,
      body: jsonEncode({
        'message': message,
        'tree': newTreeSha,
        'parents': parents,
        'author': {
          'name': authorName,
          'email': '$authorName@vcs.local',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }
      }),
    );

    if (commitResponse.statusCode != 201) {
      throw Exception('Failed to create commit: ${commitResponse.body}');
    }
    final newCommitSha = jsonDecode(commitResponse.body)['sha'];

    print('🔗 [4/4] Updating branch reference (${preview.branch})...');
    final refUrl = preview.currentHeadSha != null 
        ? '$_baseUrl/repos/${preview.owner}/${preview.repo}/git/refs/heads/${preview.branch}'
        : '$_baseUrl/repos/${preview.owner}/${preview.repo}/git/refs';

    final refMethod = preview.currentHeadSha != null ? http.patch : http.post;
    final refBody = preview.currentHeadSha != null
        ? jsonEncode({'sha': newCommitSha, 'force': false})
        : jsonEncode({'ref': 'refs/heads/${preview.branch}', 'sha': newCommitSha});

    final refResponse = await refMethod(
      Uri.parse(refUrl),
      headers: headers,
      body: refBody,
    );

    if (refResponse.statusCode != 200 && refResponse.statusCode != 201) {
      throw Exception('Failed to update reference: ${refResponse.body}');
    }

    print('\n✨ Successfully pushed changes to GitHub (${preview.owner}/${preview.repo} @ ${preview.branch})!');
  }
}
