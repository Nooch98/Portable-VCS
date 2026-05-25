class VersionHistory {
  static const Map<String, String> updates = {
    '0.4.4-Experimental.1': r'''
  # 🔍 HISTORICAL INTELLIGENCE & AUDIT SANDBOXING

  This release introduces a paradigm shift in how `vcs` handles historical divergence. By implementing graph-based lineage analysis and isolated temporary workspaces, i have evolved from simple snapshots to more complex historical auditing.
  ---

  ## 🧬 NEW FEATURE: DAG-BASED LINEAGE PARSER [[ TAG: HISTORY-PARSER ]]

  • **Divergence Detection Engine**: Introduced a robust directed acyclic graph (DAG) analyzer to navigate snapshot ancestry.
    - **LCA Resolution**: Implemented a sophisticated Lowest Common Ancestor (LCA) algorithm to automatically detect divergence points in parallel branches.
    - **3-Way Diff Intelligence**: The system now provides automated, high-precision reporting on side-by-side modifications and potential conflict hotspots during multi-track comparisons.

  ---

  ## 🏗️ NEW FEATURE: AUDIT SANDBOX SYSTEM [[ TAG: SNAPSHOT-SANDBOX ]]

  • **Volatile Reconstruction**: Added the capability to materialize any historical snapshot into an isolated, temporary system environment for manual review.
    - **Zero-Footprint Auditing**: Snapshots are provisioned to volatile system storage, ensuring the integrity of the live repository while allowing full IDE compatibility for visual merge conflict resolution.
    - **Safe Lifecycle Management**: Introduced the `vcs clean` utility, a transparent management tool designed to reclaim storage by purging obsolete sandbox environments with detailed operational feedback.
  ''',
    '0.4.3-Experimental.2': r'''
  # 🧠 OPERATIONAL INTELLIGENCE & STORAGE SAFEGUARDS

  This release shifts the focus from basic repository management to proactive infrastructure awareness, introducing predictive analytics for lifecycle management and critical storage safety buffers.
  ---

  ## 📈 NEW FEATURE: SNAPSHOT INSIGHT ENGINE [[ TAG: STATS-PREDICTIVE ]]

  • **Predictive Growth Analytics**: Expanded the `vcs stats` engine to calculate the operational lifecycle of the vault.
    - **Velocity Mapping**: Integrated a growth trend analyzer that calculates `snapshots`/`day` based on the delta between the vault creation date and current activity, allowing for accurate storage exhaustion forecasting.
    - **Density Metrics**: Added comprehensive data on metadata overhead vs. raw blob storage, providing users with transparent insights into indexing efficiency and repository health.

  ---

  ## 💾 NEW FEATURE: PRE-FLIGHT STORAGE VALIDATOR [[ TAG: STORAGE-GUARD ]]

  • **Capacity Check**: Implemented a mandatory pre-flight disk space verification engine triggered before any destructive write operation (`push`) or data reconstruction (`pull`).
    - **Cross-Platform Drive Scanner**: Engineered a native bridge to `fsutil`/`wmic` on Windows and `df` on POSIX systems to accurately query available volume capacity before transaction initiation.
    - **Fail-Safe Abort Protocol**: Added a non-intrusive safety gate that calculates required allocation bytes vs. available system space, blocking operations with high-fidelity error reporting before potential data corruption caused by disk full errors.
  ''',
    '0.4.3-Experimental.1': r'''
  # 🩺 INTELLIGENT INITIALIZATION & MARKDOWN DIAGNOSTICS

  This release elevates repository setup and health tracking by introducing contextual workspace awareness during initialization and rich document exports for system diagnostics.
  ---

  ## 💡 NEW FEATURE: CONTEXTUAL PROJECT DETECTOR [[ TAG: INIT-SMART ]]

  • **Interactive Language Sentinel**: Upgraded `vcs init` to scan the active workspace for language-specific project descriptors (such as `pubspec.yaml`, `package.json`, `Cargo.toml`, `requirements.txt`, or `go.mod`).
    - **Recommended .gitignore Generator**: If no exclusion structure exists, the engine prompts the user to auto-generate a tailored `.gitignore` pre-populated with standard production bypass rules for their detected stack, preventing repository bloating.
    - **Override Protection**: Rigidly blocks generation if a `.gitignore` already exists, ensuring custom structures remain untouched.

  ---

  ## 📄 NEW FEATURE: MARKDOWN DIAGNOSTIC REPORTS [[ TAG: DOCTOR-EXPORT ]]

  • **Automated Markdown Reporter**: Re-engineered `vcs doctor` to act as an offline auditor, writing a comprehensive audit trail to disk as a structured Markdown file (`vcs_doctor_report_[timestamp].md`).
    - **ANSI Sanitization Engine**: Embedded a rigid regex-based ANSI escape sequence filter (`stripAnsi`) to strip out terminal styling codes, ensuring the generated Markdown document remains perfectly clean, formatted, and legible.
    - **Dual-Stream Dispatcher**: Dynamically maps validation flags into simultaneous console colors and formatted Markdown logs in a single runtime pass.
  ''',
    '0.4.2-Experimental.2': r'''
  # 🚀 PORTABLE RELEASE ARCHITECTURE & TERMINAL UX UPGRADE

  This release formalizes the "Distribution" tier of Portable VCS, introducing an isolated, sandboxed release packaging engine, while significantly boosting terminal visibility and core diagnostic capabilities.
  ---

  ## 📦 NEW FEATURE: PORTABLE RELEASE & ISOLATED WORKSPACES [[ TAG: REL-DIST ]]

  • **Immutable Distribution Engine**: Implemented `vcs release` subsystem to generate secure, encrypted archives tailored for distribution. 
    - **Isolation via Temporary Sandboxing**: Executing a release (`vcs release public`) automatically decrypts the archive into a volatile OS-level temporary directory, ensuring the local development environment remains pristine.
    - **Isolated VS Code Launch**: Seamlessly triggers a dedicated VS Code instance pointing to the volatile workspace, abstracting complexity for the end-user while maintaining repository integrity.
    - **Recursive Ignore & Manifests**: Automatically respects existing `.gitignore` and `ignore_rule.dart` structures during the packaging phase, ensuring only relevant production files are distributed.

  ---

  ## 🖥️ TERMINAL UX & DIAGNOSTIC ENHANCEMENTS [[ TAG: UX-CLI ]]

  • **Dynamic Status Pre-flight (`status --ignored`)**: Extended the argument parser for `vcs status` to support the `--ignored` flag.
    - **Exclusion Compilation**: The engine now dynamically resolves and lists all files currently bypassed by active recursive exclusion structures, providing immediate transparency into why specific files are not appearing in snapshots.
  
  • **Synchronous Progress Visualization**: Injected a non-blocking, clean visual progress indicator into the `stdout` stream during high-latency cryptographic and compression pipelines.
    - **Non-blocking UI**: Maintains stability in asynchronous I/O streams while providing the user with real-time feedback during long-running vault operations.

  ---

  ## ⚙️ CORE STABILITY & PATTERN MATCHING [[ TAG: CORE-STABILITY ]]

  • **Recursive Pattern-Matching Evolution**: Deepened the logic within `/lib/models/ignore_rule.dart` to interpret complex, multi-level recursive structures modeled after modern industry standards.
    - **Deep Matching**: Increased precision for nested folder bypasses, ensuring that deep-tree exclusions (`/dir1/dir2/dir3/*.log`) behave predictably across all supported host Operating Systems.
  ''',
    '0.4.2-Experimental.1': r'''
  # 🗺️ THE STRATEGIC PLANNING ENGINE & HIGH-SPEED TRAVERSAL CORE

  This major sub-release introduces a completely new, offline-first development planning subsystem driven via CLI and standard JSON schemas, while drastically accelerating the file-tree tracking core through a new lightweight native timestamp pre-filtering architecture.
  ---

  ## 📝 NEW FEATURE: LOCAL STRATEGIC ROADMAP SUBSYSTEM [[ TAG: PLAN-CORE ]]

  • **Birth of the Native Milestone & Task Planner**: Designed and implemented a localized project planner powered by a structured `roadmap.json` schema inside the repository root, operating entirely offline without external dependencies.
    - **Visual Tree Rendering (`roadmap`)**: Built a brand new terminal compiler that translates raw JSON milestones into an elegant, color-coded visual hierarchy using tree-brackets, showing versions, titles, custom category tags, and completion progress metrics at a glance.
    - **System Editor Interoperability (`edit` / `init`)**: Created a non-blocking bridge to launch the host OS default text/code editor for rapid batch modifications, backed by an atomic validation loop that catches `FormatException` syntax issues before saving changes.
    - **Granular CLI Manipulators**: Engineered specialized sub-commands for quick, single-line updates without opening files.

  ### 🚀 ROADMAP COMMAND EXAMPLES:
  • **View Tree**: `vcs roadmap`
  • **Initialize Template**: `vcs roadmap init`
  • **Batch Edit in Editor**: `vcs roadmap edit`
  • **Add Milestone**: `vcs roadmap add "0.5.0" "Enterprise Hardening"`
  • **Add Scoped Task**: `vcs roadmap task "0.5.0" "Refactor I\O memory streaming" --task-tag IO`
  • **Toggle Task State**: `vcs roadmap done TSK-012`
  • **Remove Milestone**: `vcs roadmap rm "0.4.2-Experimental.2"`

  ---

  ## ⚡ INTELLECTUAL INDEXING & TRAVERSAL ACCELERATION [[ TAG: PERF-FINGERPRINT ]]

  > [!WARNING]
  > **CRITICAL MIGRATION NOTICE FOR FIRST RUN**
  > Due to the structural upgrade of the indexing core, your very FIRST execution of `vcs status` or `vcs push` after updating WILL flag your entire working tree as `[~] MODIFIED`.
  > 
  > This is expected behavior: legacy indices lack the OS native timestamp metadata required by the new engine. Execute your first `vcs push` to bake the updated schema format into the storage vault. Subsequent operations will then leverage the instant ~400% performance optimization.
  ---

  • **Timestamp-Assisted Pre-Filtering (`buildFingerprint`)**: Integrated a new optimization layer into the core tree-traversal algorithm to perform ultra-fast initial evaluation passes using native operating system timestamps (`file.lastModifiedSync()`).
    - **SHA-256 Block Stream Avoidance**: The engine now checks file metadata states against existing repository delta-indices before opening heavy cryptographic streaming pipelines. If a file shows zero timestamp mutation, heavy cryptographic recalculation is bypassed entirely.
    - **Massive Latency Reduction**: Cuts down `vcs status` and pre-push validation processing times by up to 400% on large-scale production workspaces containing massive unchanged directory layers, ensuring instant feedback loops.

  ### 🚀 PERFORMANCE COMMAND EXAMPLES:
  • **High-Speed Status**: `vcs status`
  • **Optimized Snapshot Push**: `vcs push "Incremental changes"`
  ''',
    '0.4.1-Experimental.2': r'''
  # 🛡️ THE STORAGE PRE-VALIDATION & HEALTH ALIGNMENT LAYER

  This update introduces real-time system storage pre-validation across data-moving boundaries (push, pull, trackSwitch) to prevent block corruption, unifies cross-platform paths via canonical resolution, and locks down core execution stability within terminal I/O streams.
  ---

  ## 💾 ATOMIC STORAGE PRE-VALIDATION [[ TAG: VOL-GUARD ]]

  • **Proactive Volume Check Subsystem**: Implemented a non-destructive hardware space verification pipeline powered by native OS bindings (`wmic` on Windows; `df` on Unix/macOS) executing completely in memory before any I/O stream opens.
    - **External Drive Protection (`push`)**: The engine estimates the packed snapshot footprint plus an encryption metadata cushion (~64KB). If the target USB or external HDD lacks bytes, the transaction aborts atomically *before* mutating `meta.json` or writing partial `.vcs` streams.
    - **Workspace Safeguard (`pull` & `trackSwitch`)**: Computes total uncompressed file sizes from the decrypted Zip archive, blocking local deployment if the host machine's drive is full, avoiding corrupted or truncated workspaces.
  • **Auto-Sanitization of Volatile Garbage**: Upgraded the `doctor` core loop to actively identify and sweep away dead residual artifacts (`.tmp_*`) left by interrupted pushes or hardware disconnects, moving from passive diagnosis to active self-healing.

  ---

  ## 🗺️ CANONICAL PATH SANITIZATION & POSIX MAPPING [[ TAG: PATH-ALIGN ]]

  • **Cross-Platform Cross-Over Fix (`status`)**: Overhauled file-tree evaluation to completely eliminate path-mismatch false positives when working interchangeably between Windows (`\`) and Unix (`/`).
    - **Canonical Symlink Resolution**: Injected `file.resolveSymbolicLinksSync()` to extract real physical paths, preventing loop barriers or duplicates caused by directory shortcuts or alias points.
    - **POSIX Normalization Engine**: Forced all internal key-matching and `.gitignore` parsing structures to map onto unified forward-slash (`/`) boundaries. Exclusion patterns (like `build/` or `*.log`) now evaluate flawlessly regardless of the host OS terminal style.

  ---

  ## ⚙️ STABLE CORE FLOWS & TERMINAL ISOLATION [[ TAG: CORE-STABILITY ]]

  • **Preservation of Stable Blind Input**: Retained the original síncrono `_readHiddenLine` utility using standard native `stdin.echoMode` switches.
    - **Zero Stream Contention**: By bypassing character-by-character interception loop diagnostics, the system ensures that interactive confirmation triggers (`y/N`) executed within async file-locking contexts (`_withLock`) never bottleneck or suffer from I/O resource deadlock.
  ''',
    '0.4.1-Experimental.1': '''
  # ⚡ THE RETROACTIVE INDEXING & HEALTH ALIGNMENT

  This update introduces retroactive delta-indexing for legacy storage blocks, stabilizes global variable scopes within the diagnostic core, and closes critical security loops during remote repository repair.
  ---

  ## 🩺 CRYPTOGRAPHIC REPAIR & REINDEXING [[ TAG: RETRO-ALIGN ]]

  • **New Feature: `vcs doctor --reindex` (or `-i`)**: Implementation of a safe, retroactive indexing pipeline for legacy snapshots. 
    - **Native Decryption Hook**: The engine now securely mounts old blocks using the core `readSnapshot` subsystem, requesting the user password exactly once.
    - **Bypass Acceleration**: Extracts the encrypted historical `fingerprint` structure and recalculates the structural Fast-Diff JSON mapping in `/index` to restore instant access for delta-based tools like `vcs di`.
  • **Disaster Recovery Resiliency**: Patched the physical scanner to seamlessly skip temporary artifacts (`.tmp_*`) and safely isolate corrupt or incomplete block hashes without freezing execution threads.

  ---

  ## 📁 ARCHITECTURE & VARIABLE LIFECYCLE [[ TAG: SCOPE-FIX ]]

  • **Global Diagnostic Scope**: Refactored the core execution loop inside the `doctor` subsystem. Elevated the tracking array `snapshotsLackingIndex` to a global level within the function scope.
    - **The Bug**: Prior iterations isolated the array inside the physical existence `if` blocks, causing scope-leaks and crash barriers when the terminal attempted to render the final summary dashboard.
    - **The Fix**: The structural map is now persistent across all diagnostic validation stages, ensuring consistent metrics in both silent scans and repair runs.
  • **ArgParser Command Wiring**: Explicitly wired the `--reindex` and `--rebuild` flags into the root CLI dispatcher (`result.command`), separating physical raw header reconstructions from index-table updates.

  ---

  ## 📊 SMART SUMMARY & INTERACTIVE METRICS [[ TAG: UI-CLEANUP ]]

  • **Adaptive Summary Output**: The terminal dashboard now intelligently detects when a repair cycle has successfully realigned storage systems.
    - **Contextual Notifications**: If the system detects external warnings (such as a missing local `.gitignore`), but storage indices are 100% fixed, the CLI prints a dedicated status update: `⚡ Reindexing completed successfully. Core storage indices are now aligned.`.
  • **Color Leak Guard**: Embedded rigid ANSI reset anchors to prevent color bleeding when alternating between missing configuration alerts (Yellow) and successful delta alignment flags (Magenta).
  ''',
    '0.4.0-Experimental.2': '''
  # 🩺 THE SEMANTIC HYGIENE & HISTORICAL ALIGNMENT

  This update fixes some bugs from the previous release, improves how files are categorized in both status and log commands, and removes an unstable feature.
  ---

  ## 🛑 COMMAND LIFECYCLE [[ TAG: CLEANUP ]]

  • **Removed Command: `vcs adopt`**: This feature has been completely removed from the CLI due to detected incompatibilities with other core system commands during execution.

  ---

  ## 🧪 ADVANCED TESTING & SEMANTIC CLASSIFICATION [[ TAG: STATUS-REFINE ]]

  • **Introduction of the `🧪 TESTS` Group**: Isolated test suites from code logic. The system now cross-checks file patterns (`*_test.dart`, `*.spec.js`) and structural path roots (`/test/`, `/test_driver/`) to avoid layout pollution in the active development view.
  • **Documentation Engine Overhaul (`ℹ️ DOCS`)**: Extended native support beyond Markdown to include major technical formats: **AsciiDoc (`.adoc`)**, **reStructuredText (`.rst`)**, and **Plain Text (`.txt`)**.
  • **Case-Insensitive Legal & Log Mapping**: Patched a string-casing bug in `p.basename` analysis. Key repository structures without common extensions (e.g., `license`, `changelog`, `readme`) are now successfully captured regardless of lowercase mutations.
  • **Expansion of Core Extension Palettes**: Added modern backend, mobile, and styling targets to prevent fallback leaks into `📄 OTHER`:
    - *Logic Layer:* `.java`, `.kt` (Kotlin), `.swift`, `.cs` (C#).
    - *Asset Layer:* `.ttf`, `.otf`, `.woff`, `.woff2` (Font packages).
    - *Config Layer:* `.conf`, `.ini`, `.env`.

  ---

  ## 📜 RETROACTIVE HISTORICAL TREE-VIEW [[ TAG: LOG-EVOLUTION ]]

  • **Sub-Prefix Branching Optimization**: Embedded the structural categorization crawler directly into the `vcs log` engine via a safe, non-decrypting pre-parser.
  • **Conditional Tree Rendering**: The `summary`, `standard`, and `full` log views now natively build a visual ASCII distribution tree mapping the composition of historical snapshots.
    - **Zero-Waste Filter**: The system automatically omits categories without active mutations to maximize terminal real estate.
  
    ```terminal
    📜 Snapshot history [Track: main]
    ═* [02] b7a8c9d2f4e1 (latest)
     |      Date:       2026-05-16 20:00:00
     |      Author:     Nooch98
     |      Message:    feat: stabilize core system
     |      Changes:    4 file(s) (+2 ~2 -0)
     |      ├── 🛠️  LOGIC: 2 file(s)
     |      ├── 🧪  TESTS: 1 file(s)
     |      └── ℹ️  DOCS:  1 file(s)
    ```

  ---

  ## 🎨 UNIVERSAL TERMINAL SYNTAX HIGHLIGHTING [[ TAG: RENDER-ENGINE ]]

  • **Multi-Environment Token Support**: The Markdown rendering engine (`_renderMarkdown`) now features an smart adaptive lexer that highlights native commands, flags, and system outputs inside code blocks without needing specialized language tags.
    - **Cross-Platform Coverage**: Fully recognizes syntax patterns for traditional Linux|macOS Shells (`bash`) and Windows environments (`powershell`).

    ### VCS CLI
    ```terminal
    vcs log --full
    ```

    ### PoweShell
    ```terminal
    Invoke-WebRequest -Uri https://github.com
    ```

    ### Bash
    ```Terminal
    curl -I --connect-timeout 5 https://google.com
    ```
  ''',
    '0.4.0-Experimental.1': '''
  # 🌐 THE PORTABILITY & SMART OPENER RELEASE

  This major experimental update breaks the directory dependency chain. VCS now features intelligent cross-directory execution, dynamic hardware target mapping, and advanced index scoping.
  ---

  ## 📂 SMART NAVIGATION & PORTABILITY [[ TAG: ZERO-CONFIG ]]

  • **New Command: `vcs open`**: A smart, context-unbound opener tool. Can be executed from any terminal path without requiring a local initialized repository.
  • **New Command: `vcs adopt`**: Introduced an interactive recovery and linking engine. Scan your connected Vault, view available remote repositories, and instantly regenerate a matching `.vcs/local_meta.json` in any folder to gain immediate workspace control.
  • **Optimized Windows Execution**: Designed using decoupled `cmd /c start ""` wrappers for seamless OS-level path resolution.

  ---

  ## 🔍 INDEXING & INSPECTION ENGINE [[ TAG: NEW-CORE ]]

  • **New Command: `vcs di`**: Implementation of the **Delta-Index Viewer**. Allows for near-instant inspection of any snapshot's file structure without requiring decryption of the data blobs.
    - **High-Precision Filtering**: Includes native support for the `--ext` flag to isolate specific file families (e.g., `.dart`, `.json`) in large repositories.
  • **Partial Context Bootstrapping**: Modified `loadRepoContext(silent: true)` to grant read access to the USB sub-systems even if local metadata is missing. This is the foundation that allows `open`, `adopt` and `list` to work globally.

  ---

  ## 🎨 RENDERING ENGINE REFINEMENTS [[ TAG: UI-TWEAKS ]]

  • **Native Syntax Highlighting**: Integrated the `highlight` Abstract Syntax Tree (AST) engine natively inside `_renderMarkdown`. The formatter now natively and independently supports structured code blocks in **Python**, **Dart**, **Go**, **JSON**, **JavaScript**, **TypeScript**, **Rust**, **C++** and **HTML**, applying full color mapping using direct ANSI palettes.

    ### Python

    ```python
    def vault_status(connected: bool):
        # Technical health check snapshot preview
        if not connected:
            print("❌ Vault offline")
            return 500
        
        assets = ["core.vcs", "meta.json"]
        for index, file in enumerate(assets):
            print(f"[{index}] Encrypting: {file}")
        return 200
    ```

    ### Dart

    ```dart
    void main() async {
      final String version = "0.4.0";
      print("Booting version: \$version");
      await loadRepoContext(silent: true);
    }
    ```

    ### Go

    ```go
    package main
    import "fmt"

    func main() {
        fmt.Println("VCS Core: Path resolver initiated.")
    }
    ```

    ### JSON

    ```json
    {
      "status": "success",
      "vault": "core.vcs",
      "encrypted": true,
      "files_count": 42
    }
    ```

    ### JavaScript

    ```javascript
    const path = require('path');

    function resolveVcsPath(target) {
        console.log(`Resolving route: \${target}`);
        return path.join(__dirname, '.vcs', target);
    }
    ```

    ### TypeScript

    ```typescript
    interface VcsConfig {
        readonly path: string;
        isLogged: boolean;
    }
    ```

    ### Rust

    ```rust
    fn main() {
        let is_valid: bool = true;
        if is_valid {
            println!("Formatting alignment test passed.");
        }
    }
    ```

    ### C++

    ```cpp
    #include <iostream>

    void checkSystem() {
        std::cout << "Engine verification initiated." << std::endl;
    }
    ```

    ### HTML

    ```html
    <div class="terminal-table">
      <span class="border-cyan">┃</span>
      <p class="cell-text">Value</p>
    </div>
    ```

  • **Table Layout Optimization**: Refined the cell padding and boundary rendering for Markdown tables to improve visual readability across different terminal sizes.
    [[ WARNING: WORK-IN-PROGRESS ]] Column alignment is more stable but still experimental; complex nested ANSI styles may cause minor shifts.
  • **Path & Route Highlighting**: Enhanced the inline formatter to automatically detect, isolate, and apply distinct visual weight to system paths and file routes.
  • **Formatting & Indent Fixes**: Patched the parsing loops in `_renderMarkdown` to capture original leading spaces, preventing the engine from destroying native alignment in nested lists or subcommand options.
  ''',

    '0.3.9-Experimental.2': '''
  # 📦 THE STABILITY & UI REFINEMENT

  This update cycle focuses on data integrity, high-precision file tracking, and the expansion of the Hooks ecosystem. UI components are in active development.

  ---

  ## 🎨 UI & RENDERING ENGINE (BETA) [[ WARNING: IN-PROGRESS ]]
  
  • **Experimental Table Support**: Added initial support for Markdown tables.
    [[ WARNING: BUG ]] The column alignment is not yet perfect and may shift with complex ANSI styles.
  • **Parser Limitations**: The Markdown parser is in early stages.
    [[ RED: KNOWN-ISSUE ]] The syntax separator `|:--- |` is currently not filtered and will appear in the output.
  • **Context Color Recovery**: Initial implementation of `restoreColor` logic to prevent color bleeding after badges.

  ---

  ## ⚙️ CORE & SYNCHRONIZATION [[ TAG: INTEGRITY ]]

  • **Precision Delta Tracking**: Fixed a critical bug in the `push` engine.
    The system now performs a physical-to-memory cross-check using `listSync` and `existsSync`.
    [[ RED: FIX ]] Deletions are now correctly flagged as [[ CRITICAL: DELETED ]] instead of Modified.
  • **Atomic File Crawler**: New `buildFingerprint` function to handle OS-level locks (e.g., `vcs.exe.old`).
    [[ SYSTEM: OS-LOCK-HANDLING ]] Prevents corrupted fingerprints in snapshot metadata.
  • **Enhanced Push Preview**: Redesigned pre-confirmation UI using `enum`-based counting logic for a 100% parity check.

  ---

  ## 🪝 PRO-GRADE HOOK TEMPLATES [[ TAG: AUTOMATION ]]
  
  Introducing a suite of automation scripts in `templates/hooks/` to standardize repository health:

  | Hook Name | Protection | Target |
  |:--- |:--- |:--- |
  | `check_tools` | TODO Scanner | `\bTODO \b` |
  | `check_cleanup` | Conflict Guard | `<<<<<<<` |
  | `forbidden_files` | Security Guard | `.env`, `.log` |
  | `secrets_detects` | Credential Shield | API Keys / Tokens |

  ---

  ## 🐞 FIXES & REFINEMENTS

  > [!WARNING]
  > **Windows Environments**: It is recommended to close any processes using the executable before performing a deep prune due to file-lock constraints.

  • **Path Normalization**: Reinforced `_normalizeRelativePath` logic.
    [[ SUCCESS: FIXED ]] Resolved mixed-slash issues: [[ WHITE: / ]] vs [[ WHITE: \\ ]].
  • **Performance**: `tree` and `ancestry` commands now utilize the `delta-index` for faster metadata traversal.
  • **Summary Logic**: Fixed synchronization between log deletion reports and console preview.

  ---
  [[ MAGENTA: VCS v0.3.9-Exp.2 ]] [[ DARK: 2026-05-13 ]]
  ''',

    '0.3.9-Experimental.1': '''
  ### ⚡ THE DELTA-INDEX ENGINE (NATIVE SEARCH ACCELERATION)
  This version introduces a new indexing layer, enabling near-instant file discovery by eliminating unnecessary decryption cycles.

  - **High-Speed Snapshot Indexing**: Introduction of the `delta-index` system. Every snapshot now generates a lightweight map of its contents, allowing the VCS to verify file existence without accessing encrypted blobs.
  - **3-Phase Hybrid Search**: A new architecture designed for maximum efficiency:
    1. **Metadata Phase**: Instant scans of snapshot messages and technical notes.
    2. **Index Phase**: Rapid file-name matching using pre-computed indices.
    3. **Deep Content Phase**: On-demand decryption for high-precision text searching.
  - **Legacy-Aware Compatibility**: Native support for older snapshots. The system automatically detects snapshots without indices and switches to an adaptive scan mode.

  ### 🔍 INTELLIGENT SEARCH & UX
  - **Context-Aware Outputs**: The engine now distinguishes between file-level and content-level queries, providing clean file lists for path searches and detailed snippets for text searches.
  - **Optimized Decryption Bypass**: Implemented a "Smart Filter" that prevents password prompts or decryption if the index doesn't match the search criteria.
  - **Dynamic IO Management**: Optimized terminal output with a non-intrusive progress overlay that maintains console cleanliness.

  ### 🩺 COMMAND EVOLUTION & SYSTEM HEALTH
  - **Doctor & Verify (Index-Linked)**: The integrity engine now verifies the `delta-index` health. `vcs doctor` can now detect missing or corrupted indices and offers to rebuild them from the encrypted sources.
  - **Enhanced Status (Pre-Index Analysis)**: The `status` command is now faster and more precise, utilizing the new indexing logic to categorize changes into Logic, Assets, and Config with zero latency.
  - **Prune & Garbage Collection**: The `prune` engine now includes **Index Sync**. When a snapshot is deleted, its associated delta-index is automatically purged to prevent storage bloat.
  - **Advanced Stats**: Updated the `stats` dashboard to include "Indexing Coverage," showing the percentage of the repository that has been optimized for high-speed search.

  ### 🛠️ CORE REFINEMENTS
  - **Universal Path Normalization**: Native support for cross-platform pathing, ensuring consistent results across Windows, Linux, and macOS.
  - **Automated Lifecycle**: Every `push` now triggers an atomic index generation, ensuring your search database is always up to date.
  - **Security-on-Demand**: Refined authentication flow so the password prompt only triggers when deep decryption is strictly required.
    ''',

    '0.3.8-Experimental.2': '''
  ### 🪝 THE AUTOMATION ENGINE (NEW ECOSYSTEM)
  This update introduces a fully-featured Hooks System, transforming the VCS from a storage tool into an automated development environment.

  - **Modular Hook Architecture**: Implementation of a new dedicated `HookManager` that handles the lifecycle of automation scripts.
  - **Universal Script Support**: Native integration for `.ps1` (PowerShell), `.bat`/`.cmd` (Windows Batch), and `.sh` (Bash). The system intelligently selects the appropriate runner for each environment.
  - **Dynamic Auto-Run Suite**: Integration of a "Pre-Push" execution engine. The system automatically scans for scripts marked as `auto` and runs them in sequence before any data is encrypted or saved.
  - **Smart Resolver Logic**: Added a file-discovery engine that locates hooks regardless of their extension, allowing for a seamless cross-platform workflow (e.g., creating a hook on Windows and running it on Linux).

  ### ⌨️ NEW COMMAND: `vcs hook`
  - **Full CRUD for Automation**: Added `create`, `edit`, and `exec` commands to manage your automation scripts directly from the CLI.
  - **Execution Control**: Introduction of "Modes" (`auto` vs `man`). 
    - `auto`: The hook runs automatically during the `push` process.
    - `man`: The hook only runs when explicitly called via `vcs hook exec`.
  - **Integrated IDE Link**: Built-in logic to open hook scripts in **VS Code** (priority) or system default editors like **Notepad/Nano**.

  ### 🛡️ INTEGRITY & PORTABILITY
  - **Execution Bypass Policy**: Implemented automatic PowerShell execution policy handling (`-ExecutionPolicy Bypass`) to ensure hooks run on guest machines without manual configuration.
  - **Push Guard**: The `push` command now acts as a gatekeeper; if any automatic hook returns a failure (exit code != 0), the snapshot process is aborted to protect the repository from corrupted or broken code.
  - **Verbose Console Feedback**: Designed a new terminal output for hooks that includes real-time status, script output, and color-coded success/failure indicators.
    ''',

    '0.3.8-Experimental.1': '''
  ### 🛡️ HARDWARE ARMORED & MERGE READY
  This update introduces a critical layer of safety for both metadata persistence and multi-track operations, ensuring the VCS remains stable during complex workflows.

  - **Merge Check (Read-Only)**: A new preventive engine for track fusion. Before performing a merge, the system executes a non-destructive "dry-run" that verifies the physical existence of the common ancestor and the integrity of the target snapshots.
  - **Triple-Layer Backup Rotation**: I have upgraded the metadata engine with a **3-stage circular backup system** (`.bak1`, `.bak2`, `.bak3`). This allows for deep recovery even if a write operation is corrupted during a critical update.
  - **Smart Guard**: The writing engine now includes a **Relative Size Validator**. If the new metadata is significantly smaller than the previous version (detected truncation), the system aborts the write and alerts the user to prevent massive data loss.

  ### 🏷️ TAG & REPO HYGIENE
  - **Global Orphan Tag Detection**: The `doctor` and `prune --garbage` commands now perform cross-track analysis to identify and remove labels pointing to non-existent or deleted snapshots.
  - **Integrity-Aware Status**: The `status` command now performs a "Physical Heartbeat" check. If the last snapshot of your active track is missing from the USB, you'll receive a critical alert before attempting new changes.

  ### 📊 DIAGNOSTICS & UX
  - **Enhanced Repo Stats**: Added a new **"Health & Tags"** section to the `stats` command, providing a quick overview of milestone distribution and repository synchronization health.
  - **Physical Desync Alerts**: Improved error reporting when the local project and the remote vault are out of sync due to external file deletion.

  ### 🐞 FIXES & REFINEMENTS
  - **Prune Logic Fix**: Resolved a bug where orphan tags were not being cleaned unless a snapshot was also being deleted.
  - **Safe-Rename Fallback**: Reinforced the write process to handle OS-level file locks more gracefully during the rename phase.
    ''',

    '0.3.7-Experimental.2': '''
  ### 🩺 THE DOCTOR'S UPGRADE (HARDWARE RESILIENCE)
  I have transformed the `doctor` command from a simple metadata checker into a **Full Recovery & Integrity Engine**. This update focuses on surviving physical hardware failure and data corruption.

  - **Integrity Deep Scan (SHA-256)**: The system now performs a physical-to-metadata cross-check. It reads every encrypted blob on the USB and verifies its SHA-256 hash against the index to detect "bit-rot" or drive failure.
  - **Recovery Mode (`--rebuild`)**: A new disaster recovery tool. If your `meta.json` is lost or corrupted, the VCS can now scan the USB drive physically and "resurrect" the repository by reading the new plain-text headers.
  - **Redundant Flat Headers**: Every `.vcs` file now stores its `trackName` and `parentId` in a non-encrypted header. This allows the system to be self-describing even without a central database.

  ### 🏗️ MODEL REFINEMENT & STABILITY
  - **Format Version 4**: Updated the `RepoMeta` schema to support more robust tracking and future-proof the recovery logic.
  - **Enhanced Snapshot Logs**: Added `changeSummary` requirements to the `SnapshotLogEntry` model to ensure traceability of reconstructed data.
  - **Strict Validation**: The engine now enforces required parameters during reconstruction to prevent "orphan" snapshots that could break the lineage tree.

  ### 🐞 FIXES & UX
  - **Parameter Guard**: Fixed a missing argument bug in the snapshot creation logic that caused failures in recovery scenarios.
  - **Improved Diagnostics**: The `doctor` report now clearly distinguishes between Local Project, Drive Identity, and Remote Repository Integrity.
    ''',
    
    '0.3.7-Experimental.1': '''
  ### 🌳 ANCESTRY & LINEAGE SYSTEM (THE GENEALOGY UPDATE)
  I have transformed the flat snapshot history into a **Directed Acyclic Graph (DAG)**. The VCS now understands the "biological" relationship between every version.

  - **Parent Tracking:** Every snapshot now stores a `parentId` to trace development paths even after pruning.
  - **Branching Metadata:** Tracks now record `originSnapshotId` and `originTrackName` to mark exact moments of divergence.
  - **New Command: `ancestry`:** A visual, tree-like representation of your history showing `Parent → Child` connections.

  ### ⚔️ ADVANCED 3-WAY DIFF ENGINE
  Preparing the ground for future Merges, the `diff` command has been significantly upgraded.

  - **Automatic Common Ancestor Discovery:** The engine automatically walks back the lineage to find the "Common Base" for comparisons.
  - **Triple-View Analysis:** Beyond simple "A vs B", the system now performs a **3-way analysis** (Base vs Left vs Right).
  - **Conflict Detection:** Identifies files modified in both branches with divergent results, marked with a `⚠ CONFLICT` warning.
  - **Status Indicators:** New visual cues: `←` (Left mod), `→` (Right mod), and `=` (Identical changes).

  ### 🕹️ INTERACTIVE UX & NAVIGATION
  - **Interactive Changelog Explorer:** The new `--list` (or `-l`) flag allows you to browse the entire evolution of the app through a selectable index.
  - **Markdown-Powered Menus:** The version index is now dynamically rendered using the internal Markdown engine, providing a consistent visual identity with colors and highlights.
  - **Smart Selection:** Quick-access navigation—just type the version number to jump deep into its technical history.

  ### 🛤️ ENHANCED TRACK MANAGEMENT
  - **Smart Branching:** The `track create <name>` command now supports the `--from <id>` flag to "fork" from any point.
  - **Lineage-Safe Pruning:** The `prune` engine now automatically re-links parent-child relationships to maintain genealogy.

  ### 📖 DOCUMENTATION & UX
  - **Global Legend:** Standardized technical legend for all lineage-related commands.
  - **Updated Help:** Comprehensive documentation for new branching and ancestry flags.
    ''',
    
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

  static List<String> get allVersions => updates.keys.toList();

  static String getMarkdown(String version) {
    return updates[version] ?? 'No changelog details found for version \$version.';
  }

  static String getAvailableVersionsMarkdown() {
    final versions = allVersions;
    String listContent = "";
    
    for (var i = 0; i < versions.length; i++) {
      listContent += "  **[${i + 1}]** ${versions[i]}\n";
    }

    return '''
# 📜 VERSION HISTORY INDEX

> Select a version number to explore the evolution of the system.

$listContent
---
**Type the number** to view details or **'q'** to quit.
''';
  }
}
