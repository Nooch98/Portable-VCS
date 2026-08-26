import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:vcs/models/repo_meta_dots.dart';

class DotfilesService { 
  static Future<RemoteRepoDotInfo> initDotRepo({
    required Directory vaultDir,
    required String repoName,
    required String password,
  }) async {
    final sanitizedName = repoName.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final repoDir = Directory('${vaultDir.path}${Platform.pathSeparator}$sanitizedName');

    if (await repoDir.exists()) {
      throw Exception('A repository with this name already exists in the vault.');
    }

    await repoDir.create(recursive: true);
    final dotfilesDir = Directory('${repoDir.path}${Platform.pathSeparator}.vcs_dots');
    await dotfilesDir.create(recursive: true);

    final now = DateTime.now().toUtc().toIso8601String();
    final repoId = _generateRepoId();

    final meta = RepoMetaDot(
      repoId: repoId,
      projectName: sanitizedName,
      repoType: 'dotfiles',
      createdAt: now,
      updatedAt: now,
      formatVersion: 4,
      activeTrack: 'main',
      tracks: {
        'main': TrackStateDot(logs: []),
      },
      tags: {},
      entries: {},
    );

    await _saveMeta(repoDir, meta);

    return RemoteRepoDotInfo(repoDir: repoDir, meta: meta);
  }

  static Future<void> addEntry({
    required Directory repoDir,
    required String alias,
    required String absolutePath,
    String? description,
  }) async {
    final meta = await _loadMeta(repoDir);
    final fileObj = File(absolutePath);
    final dirObj = Directory(absolutePath);

    final exists = await fileObj.exists() || await dirObj.exists();
    if (!exists) {
      throw Exception('Target path does not exist on disk: $absolutePath');
    }

    final isDir = await dirObj.exists() && !await fileObj.exists();
    final portable = DotfileEntry.toPortablePath(absolutePath);

    final newEntry = DotfileEntry(
      alias: alias,
      portablePath: portable,
      isDirectory: isDir,
      addedAt: DateTime.now().toUtc().toIso8601String(),
      description: description,
    );

    final updatedEntries = Map<String, DotfileEntry>.from(meta.entries);
    updatedEntries[alias] = newEntry;

    final updatedMeta = meta.copyWith(
      entries: updatedEntries,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );

    await _saveMeta(repoDir, updatedMeta);
  }

  static String _sanitizePath(String rawPath) {
    if (rawPath.isEmpty) return rawPath;
    final nativePath = rawPath.replaceAll('/', p.separator).replaceAll('\\', p.separator);
    return p.normalize(nativePath);
  }

  static Future<void> pushDotRepo({
    required Directory repoDir,
    required String password,
    required String message,
    required String author,
  }) async {
    final meta = await _loadMeta(repoDir);
    if (meta.entries.isEmpty) {
      throw Exception('No dotfiles registered. Use "vcs dot add" first.');
    }

    final archive = Archive();
    int addedFilesCount = 0;

    for (var entry in meta.entries.values) {
      final absPath = _sanitizePath(entry.toAbsolutePath());
      final fileObj = File(absPath);

      final safeAlias = entry.alias.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');

      if (entry.isDirectory) {
        final dir = Directory(absPath);
        if (await dir.exists()) {
          await for (var entity in dir.list(recursive: true)) {
            if (entity is File) {
              final relativePath = p.relative(entity.path, from: absPath);
              final zipEntryPath = '$safeAlias/$relativePath'.replaceAll('\\', '/');
              final bytes = await entity.readAsBytes();

              archive.addFile(ArchiveFile(zipEntryPath, bytes.length, bytes));
              addedFilesCount++;
              print('📦 [PUSH] Added directory file: "${entry.alias}" -> $relativePath (${bytes.length} bytes)');
            }
          }
        }
      } else {
        if (await fileObj.exists()) {
          final zipEntryPath = '$safeAlias/${p.basename(absPath)}'.replaceAll('\\', '/');
          final bytes = await fileObj.readAsBytes();

          archive.addFile(ArchiveFile(zipEntryPath, bytes.length, bytes));
          addedFilesCount++;
          print('📦 [PUSH] Added dotfile: "${entry.alias}" -> ${p.basename(absPath)} (${bytes.length} bytes)');
        } else {
          print('⚠️ [PUSH] Physical file not found on disk: $absPath');
        }
      }
    }

    if (addedFilesCount == 0) {
      throw Exception('None of the registered dotfiles exist physically on this machine.');
    }

    final zipEncoder = ZipEncoder();
    final encodedZipBytes = zipEncoder.encode(archive);

    if (encodedZipBytes == null || encodedZipBytes.isEmpty) {
      throw Exception('Failed to encode the snapshot archive into memory.');
    }

    final encryptedBytes = _encryptBytes(encodedZipBytes, password);

    final snapshotId = _generateRepoId();
    final createdAt = DateTime.now().toUtc().toIso8601String();

    final snapshotsDir = Directory(p.join(repoDir.path, '.vcs_dots', 'snapshots'));
    await snapshotsDir.create(recursive: true);

    final blobFile = File(p.join(snapshotsDir.path, '$snapshotId.enc'));
    await blobFile.writeAsBytes(encryptedBytes);

    final activeTrackName = meta.activeTrack;
    final trackState = meta.tracks[activeTrackName]!;
    final parentId = trackState.logs.isNotEmpty ? trackState.logs.last.id : null;

    final newLogEntry = SnapshotLogEntryDot(
      id: snapshotId,
      parentId: parentId,
      message: message,
      author: author,
      timestamp: createdAt,
      fileCount: addedFilesCount,
    );

    final updatedLogs = List<SnapshotLogEntryDot>.from(trackState.logs)..add(newLogEntry);
    final updatedTracks = Map<String, TrackStateDot>.from(meta.tracks);
    updatedTracks[activeTrackName] = trackState.copyWith(logs: updatedLogs);

    final updatedMeta = meta.copyWith(
      updatedAt: createdAt,
      tracks: updatedTracks,
    );

    await _saveMeta(repoDir, updatedMeta);
    print('✨ [PUSH] Snapshot created, packed, and saved successfully.');
  }

  static Future<void> pullDotRepo({
    required Directory repoDir,
    required String password,
    String? snapshotId,
  }) async {
    print('🔍 [PULL] Loading repository metadata...');
    final meta = await _loadMeta(repoDir);
    if (meta.entries.isEmpty) {
      throw Exception('No dotfiles registered in this repository metadata.');
    }

    final trackState = meta.activeTrackState;
    if (trackState.logs.isEmpty) {
      throw Exception('No snapshots found in the active track to pull.');
    }

    final targetId = snapshotId ?? trackState.logs.last.id;
    print('🎯 [PULL] Target snapshot ID: $targetId');

    final snapshotExists = trackState.logs.any((log) => log.id == targetId);
    if (!snapshotExists) {
      throw Exception('Snapshot with ID "$targetId" not found in the active track.');
    }

    final blobFile = File(p.join(repoDir.path, '.vcs_dots', 'snapshots', '$targetId.enc'));
    if (!await blobFile.exists()) {
      throw Exception('Encrypted snapshot payload blob not found on storage for ID: $targetId');
    }

    print('🔓 [PULL] Reading and decrypting snapshot blob (.enc)...');
    final encryptedBytes = await blobFile.readAsBytes();
    final decryptedZipBytes = _decryptBytes(encryptedBytes, password);

    final tempDir = Directory.systemTemp.createTempSync('vcs_dot_pull_');
    try {
      final zipFile = File(p.join(tempDir.path, 'extract.zip'));
      await zipFile.writeAsBytes(decryptedZipBytes);

      print('📦 [PULL] Decompressing archive payload...');
      final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
      print('📦 [PULL] Total files found in decoded archive: ${archive.files.length}');

      final extractedDir = Directory(p.join(tempDir.path, 'payload'));
      await extractedDir.create(recursive: true);

      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          final f = File(p.join(extractedDir.path, filename));
          await f.parent.create(recursive: true);
          await f.writeAsBytes(data);
          print('   📄 [EXTRACT] Successfully extracted: "$filename" (${data.length} bytes)');
        }
      }

      print('🔄 [PULL] Mapping registered entries to local system paths...');
      for (var entry in meta.entries.values) {
        final targetPath = _sanitizePath(entry.toAbsolutePath());
        final safeAlias = entry.alias.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
        print('   - Alias: [${entry.alias}] -> Target path: $targetPath');

        if (entry.isDirectory) {
          final sourceSubDir = Directory(p.join(extractedDir.path, safeAlias));
          final targetDir = Directory(targetPath);

          if (await sourceSubDir.exists()) {
            await targetDir.create(recursive: true);
            await for (var entity in sourceSubDir.list(recursive: true)) {
              if (entity is File) {
                final relativePath = p.relative(entity.path, from: sourceSubDir.path);
                final destinationFile = File(p.join(targetDir.path, relativePath));
                await destinationFile.parent.create(recursive: true);
                await entity.copy(destinationFile.path);
                print('       -> Deployed directory file: $relativePath');
              }
            }
          }
        } else {
          File? sourceFile;
          final exactFile = File(p.join(extractedDir.path, safeAlias, p.basename(targetPath)));

          if (await exactFile.exists()) {
            sourceFile = exactFile;
          } else {
            await for (var entity in extractedDir.list(recursive: true)) {
              if (entity is File && p.basename(entity.path).toLowerCase() == p.basename(targetPath).toLowerCase()) {
                sourceFile = entity;
                break;
              }
            }
          }

          if (sourceFile == null || !await sourceFile.exists()) {
            print('     ❌ [ERROR] Source file for alias "${entry.alias}" was not found in the archive.');
            continue;
          }

          print('     ✅ Source file located at: ${sourceFile.path}');
          final destFile = File(targetPath);
          await destFile.parent.create(recursive: true);
          await sourceFile.copy(destFile.path);
          print('     🚀 Successfully deployed to: $targetPath');
        }
      }
      print('✨ [PULL] Process completed successfully.');
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  static Future<Map<String, dynamic>> listContents(Directory repoDir) async {
    final meta = await _loadMeta(repoDir);
    final Map<String, dynamic> result = {};

    meta.entries.forEach((alias, entry) {
      result[alias] = {
        'portable_path': entry.portablePath,
        'absolute_path': entry.toAbsolutePath(),
        'is_directory': entry.isDirectory,
        'added_at': entry.addedAt,
        'description': entry.description,
      };
    });

    return result;
  }

  static Future<Map<String, dynamic>> statusDotRepo(Directory repoDir) async {
    final meta = await _loadMeta(repoDir);
    final List<Map<String, dynamic>> entryStatuses = [];

    for (var entry in meta.entries.values) {
      final absPath = entry.toAbsolutePath();
      final fileObj = File(absPath);
      final dirObj = Directory(absPath);
      
      final exists = await fileObj.exists() || await dirObj.exists();
      
      entryStatuses.add({
        'alias': entry.alias,
        'path': absPath,
        'is_directory': entry.isDirectory,
        'exists_locally': exists,
      });
    }

    return {
      'project_name': meta.projectName,
      'active_track': meta.activeTrack,
      'total_entries': meta.entries.length,
      'entries': entryStatuses,
    };
  }

  static Future<List<SnapshotLogEntryDot>> getLog(Directory repoDir, {String? trackName}) async {
    final meta = await _loadMeta(repoDir);
    final targetTrack = trackName ?? meta.activeTrack;
    
    final trackState = meta.tracks[targetTrack];
    if (trackState == null) {
      throw Exception('Track "$targetTrack" does not exist in this repository.');
    }

    return trackState.logs;
  }

  static encrypt.Key _deriveKey(String password) {
    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    return encrypt.Key(Uint8List.fromList(keyBytes));
  }

  static List<int> _encryptBytes(List<int> data, String password) {
    final key = _deriveKey(password);
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    final encrypted = encrypter.encryptBytes(data, iv: iv);
    
    final output = <int>[];
    output.addAll(iv.bytes);
    output.addAll(encrypted.bytes);
    return output;
  }

  static List<int> _decryptBytes(List<int> encryptedData, String password) {
    final key = _deriveKey(password);
    final ivBytes = encryptedData.sublist(0, 16);
    final cipherBytes = encryptedData.sublist(16);
    
    final iv = encrypt.IV(Uint8List.fromList(ivBytes));
    final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    
    final decrypted = encrypter.decryptBytes(
      encrypt.Encrypted(Uint8List.fromList(cipherBytes)),
      iv: iv,
    );
    return decrypted;
  }

  static Future<RepoMetaDot> _loadMeta(Directory repoDir) async {
    final metaFile = File('${repoDir.path}${Platform.pathSeparator}.vcs_dots${Platform.pathSeparator}meta.json');
    if (!await metaFile.exists()) {
      throw Exception('Dotfile repository metadata not found.');
    }
    
    final jsonString = await metaFile.readAsString();
    final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
    return RepoMetaDot.fromJson(jsonMap);
  }

  static Future<void> _saveMeta(Directory repoDir, RepoMetaDot meta) async {
    final metaFile = File('${repoDir.path}${Platform.pathSeparator}.vcs_dots${Platform.pathSeparator}meta.json');
    await metaFile.parent.create(recursive: true);
    
    final jsonString = jsonEncode(meta.toJson());
    await metaFile.writeAsString(jsonString);
  }

  static String _generateRepoId() {
    final randomVal = DateTime.now().microsecondsSinceEpoch.toString();
    return md5.convert(utf8.encode(randomVal)).toString();
  }
}