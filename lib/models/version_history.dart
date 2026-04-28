class VersionHistory {
  static const Map<String, String> updates = {
    '0.3.4-Experimental.1': '''
  ### 🚀 NEW FEATURES
  - **Portable Aliases:** Create custom shortcuts that live in your USB.
  - **Smart Doctor:** Advanced diagnostics that understand multi-track repositories.
  
  ### 🛠️ IMPROVEMENTS
  - **Orphan Detection:** Listing of garbage files with safety whitelisting.
  - **Global Scanning:** The `doctor` command now verifies all tracks, not just the active one.
  - **Safety First:** Added `--dry-run` logic to `pull` operations.

  ### 🐛 BUG FIXES
  - **Semantic Updates:** Fixed a bug where the update engine suggested older versions. Now it understands version hierarchy and won't downgrade your tool.
  - **Silent Checker:** Optimized the background update checker to avoid false positive notifications.
    ''',
    
    '0.3.3-Experimental.2': '''
  ### 🎨 UI & UX
  - Polished terminal output for snapshot listings.
  - New silent update engine tooltips.
  - Fixed metadata parsing for legacy drives.
    ''',
  };

  static String getMarkdown(String version) {
    return updates[version] ?? 'No changelog details found for version \$version.';
  }
}
