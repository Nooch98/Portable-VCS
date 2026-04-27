class UpdateCache {
  final String latestVersion;
  final DateTime lastChecked;

  UpdateCache(this.latestVersion, this.lastChecked);

  bool get shouldCheck => DateTime.now().difference(lastChecked).inHours >= 24;
}
