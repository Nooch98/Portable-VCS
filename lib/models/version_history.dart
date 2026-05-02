class VersionHistory {
  static const Map<String, String> updates = {
    '0.3.5-Experimental.2': '''
  ## 🧪 PARALLEL TRACK SYSTEM (SHADOW MODE)
  I have completely overhauled how `track switch` operates. Instead of overwriting the main project files (which was risky and prone to data loss), the VCS now enables **Parallel Workspaces**.

  ### 1. The Shadow Workspace Logic
  - **Non-Destructive Switching:** Switching to a track no longer deletes your current work in the `main` directory. 
  - **Shadow Folder:** I've implemented a dedicated workspace at `.vcs/shadow_[track]`. This allows the `main` track and any experimental track to exist physically at the same time in different folders.
  - **Session Management:** A new `session.json` is created inside the USB repository. This file acts as a "heartbeat" that tells the VCS exactly which shadow track is active and where its folder is located.

  ### 2. 🛡️ Prevention of Data Corruption
  - **Isolation:** By using a separate shadow folder, I've ensured that a crash or a forced disconnection during a track switch never corrupts the primary source code.
  - **Smart Cleanup:** When you return to `main`, the VCS uses the `session.json` to identify and safely remove the shadow folder, keeping the project clean without manual intervention.
  - **Change Detection:** Before closing a shadow session, the tool checks for unpushed changes. If I find any, it will prompt for an automatic `push` to prevent the accidental deletion of experiments.

  ### 3. ⚠️ Critical: Environment & IDE Sync
  Since the shadow folder is a fresh extraction of a snapshot:
  - **Missing Dependencies:** Heavy directories like `node_modules`, `.dart_tool`, or `venv` are not part of the snapshots to keep the repository lightweight.
  - **The "Red Line" Fix:** If VS Code shows "Target of URI doesn't exist", it's because the IDE is looking for dependencies in the new shadow path. 
  
  **Action Required:** You must run the package manager (`dart pub get`, `npm install`, etc.) inside the **new** shadow window to link the dependencies to this parallel folder.

  ### 🛠️ Internal Refinement
  - **Case-Insensitive Resolution:** Track names are now resolved regardless of casing (e.g., `experimentos` vs `Experimentos`).
  - **Pathing Stability:** I've updated the logic to ensure the tool always distinguishes between the "Source" (main) and the "Shadow" workspace.
    ''',

    '0.3.5-Experimental.1': '''
  ### 🏎️ PERFORMANCE & VISIBILITY
  - **New Command: `benchmark`:** Test your USB performance with a stress test covering IOPS, sequential write, and AES-256 encryption latency. Includes a hardware rating (Gold/Silver/Bronze).
  - **New Command: `timeline`:** A new way to visualize history. View your snapshots in chronological order with customizable limits (`--limit`) and track-specific filtering.

  ### 🛠️ UX & COMMAND REFINEMENT
  - **Doctor 2.0:** Improved diagnostic logic with better repair suggestions and clearer status reporting.
  - **Enhanced Stats & Info:** Refined output for repository metrics, including better visualization of track distribution and storage impact.
  - **Polished List:** The `list` command now provides a cleaner overview of available repositories on the connected drive.
    ''',

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
