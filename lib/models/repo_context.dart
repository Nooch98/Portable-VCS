import 'dart:io';
import 'package:vcs/models/repo_meta.dart';

class RepoContext {
  final Directory usbDrive;
  final Directory remoteRepoDir;
  final Map<String, dynamic> localMeta;
  final RepoMeta remoteMeta;

  RepoContext({
    required this.usbDrive,
    required this.remoteRepoDir,
    required this.localMeta,
    required this.remoteMeta,
  });
}
