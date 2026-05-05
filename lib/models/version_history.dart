class VersionHistory {
  static const Map<String, String> updates = {
    '0.3.6-Experimental.2': '''
  ### 🛡️ ULTRA-ROBUST PERSISTENCE (USB SAFE)
  I have re-engineered the metadata engine to ensure your repository remains intact even during accidental USB disconnections or hardware failures.

  - **Atomic Multi-Stage Writes:** Every save operation now follows a "Safe-Swap" protocol: `Data -> .tmp file -> Integrity Check -> Rename`. This prevents "Zero-Byte" corruption if the process is interrupted.
  - **3-Level Backup Rotation (Time Machine):** The system now maintains a circular rotation of metadatos (`meta.json.bak1`, `.bak2`, `.bak3`). If one file is corrupted, you can roll back to three previous stable states.
  - **Physical Flush:** Forced hardware synchronization (`flush: true`) on every write, ensuring the USB controller actually commits data to the flash memory before finishing.

  ### 🔍 UNIVERSAL SEARCH & NOTES INTEGRATION
  The `search` command is now smarter and much faster by utilizing a two-phase engine.

  - **Metadata & Note Search:** Instantly find text within snapshot messages and your technical notes without needing to decrypt the entire repository.
  - **Note Highlights:** Matches found within annotations are displayed with a new yellow highlight and context preview.
  - **Interactive Deep Search:** After checking metadatos, the tool offers to proceed with a deep, decrypted search inside the files of each snapshot.

  ### 🛠️ REFINED SNAPSHOT MANAGEMENT
  - **Smart --amend:** The `push --amend` flag has been reinforced. It now automatically migrates existing notes to the new amended snapshot and blocks operations if the snapshot is linked to a Tag to prevent history inconsistency.
  - **Prune & Note Sync:** Improved the `prune` and `clearHistory` commands to handle the new backup rotation, ensuring that cleaning up old files doesn't leave orphaned `.bak` files.

  ### 🐞 STABILITY & HARDWARE COMPATIBILITY
  - **Write Fallback:** Implemented a `Copy+Delete` strategy for systems where the `rename` operation is locked by antivirus or OS indexing.
  - **Integrity Guard:** The engine now aborts any write if the resulting JSON is empty or malformed, acting as a final shield for your project history.
    ''',
    
    '0.3.6-Experimental.1': '''
  ### 📝 SNAPSHOT ANNOTATIONS (VCS NOTES)
  I have implemented a **Post-Snapshot Documentation System**. This allows you to enrich your history without changing the core snapshot data.

  - **Technical Journaling:** Add detailed technical notes to any snapshot using `vcs note "text"`. Perfect for documenting bug reproduction steps or build environment details.
  - **Multi-Note Support:** A single snapshot can have multiple annotations, creating a "thread" of information over time.
  - **Full CRUD Support:** You can add, list (via `log`), and remove notes (`--remove`, `--all`) by their index.
  - **Traceability:** Every note automatically records the author and the exact timestamp of creation.

  ### 🔍 ENHANCED VISUAL STATUS
  The `status` command has been completely redesigned for better readability and file categorization.

  - **Domain Grouping:** Files are now automatically categorized into **Logic** (code), **Assets** (images/icons), and **Configuration** (yaml/json) for faster inspection.
  - **Action Labels:** Clear, color-coded indicators for `NEW` (added), `MOD` (modified), and `DEL` (deleted) states.
  - **FileChange Logic:** Internal transition to a robust `enum`-based system for change tracking, ensuring future compatibility with merge operations.

  ### 🛠️ SNAPSHOT REFINEMENT
  - **New Feature: `--amend`:** You can now fix the last snapshot in the active track. If you forgot a file or made a typo in the message, `push --amend` overwrites the latest entry, keeping the history clean and professional.
  - **Integrated Log View:** The `log` command now renders notes inline with a new magenta 📝 indicator, including support for the `--graph` view.

  ### 🐞 STABILITY & FIXES
  - **Atomic Note Management:** Note removal includes safety checks to prevent out-of-bounds errors when targeting specific indices.
  - **Metadata Robustness:** Updated the `SnapshotLogEntry` model to support recursive JSON serialization of notes.
    ''',
    
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
