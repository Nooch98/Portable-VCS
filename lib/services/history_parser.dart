import 'package:vcs/models/snapshot_log_entry.dart';

class HistoryParser {
  final Map<String, SnapshotLogEntry> _idMap;

  HistoryParser(List<SnapshotLogEntry> allLogs) 
      : _idMap = {for (var log in allLogs) log.id: log};

  List<String> getAncestryChain(String snapshotId) {
    final chain = <String>[];
    String? currentId = snapshotId;
    
    while (currentId != null && _idMap.containsKey(currentId)) {
      chain.add(currentId);
      currentId = _idMap[currentId]!.parentId;
    }
    return chain;
  }

  String? findCommonAncestor(String idA, String idB) {
    final chainA = getAncestryChain(idA);
    final chainB = getAncestryChain(idB);
    
    for (final id in chainA) {
      if (chainB.contains(id)) {
        return id;
      }
    }
    return null;
  }
}
