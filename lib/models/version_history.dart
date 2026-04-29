class VersionHistory {
  static const Map<String, String> updates = {
    '0.3.4-Experimental.2': '''
  ### 🏷️ HUMAN-READABLE HISTORY
  - **Tagging System:** Assign friendly names (labels) to snapshots. No more copying 13-digit IDs.
  - **Smart Resolution:** `pull` now resolve tags automatically.
  - **Visual Tags:** The `log` command now highlights your labels with a 🏷️ icon in magenta.

  ### 🛡️ DATA INTEGRITY & RESILIENCE
  - **SHA-256 Checksums:** Every snapshot now includes a cryptographic hash for per-file integrity verification.
  - **Metadata Mirroring:** Automatic `.bak` redundancy for the repository database to prevent total data loss.
  - **Disaster Recovery:** The `doctor` command now auto-detects and restores corrupt JSON files from mirrors.

  ### 📊 ENHANCED DASHBOARD & UX
  - **Advanced Info:** The `info` command now displays sync timestamps, metadata update history, and a full track distribution list.
  - **Health Monitoring:** New 'Physical Health' section in dashboard to track SHA-256 coverage across the repository.
  - **Atomic Writes:** Improved metadata saving process to ensure consistency even if the USB is disconnected.

  ### 🩺 DIAGNOSTICS
  - **Optimization:** Refined orphan file detection and interrupted transaction cleanup.
  - **Deep Scan:** `doctor` now performs a physical-to-meta cross-check using cryptographic hashes.
  
  ### 🐛 BUG FIXES
  - **Semantic Versioning:** Fixed a bug in the update engine that incorrectly suggested downgrades. The tool now understands version hierarchy (v2 > v1).  
    ''',

    '0.3.4-Experimental.1': '''
  ### 🚀 NEW FEATURES
  - **Portable Aliases:** Create custom shortcuts that live in your USB.
  - **Smart Doctor:** Advanced diagnostics that understand multi-track repositories.
  
  ### 🛠️ IMPROVEMENTS
  - **Orphan Detection:** Listing of garbage files with safety whitelisting.
  - **Global Scanning:** The `doctor` command now verifies all tracks, not just the active one.
  - **Safety First:** Added `--dry-run` logic to `pull` operations.

  ### 🐛 BUG FIXES
  - **Semantic Updates:** Fixed hierarchy logic in the update engine.
  - **Silent Checker:** Optimized background update notifications.
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
