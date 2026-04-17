# Portable VCS

![Dart](https://img.shields.io/badge/language-Dart-blue)
![Version](https://img.shields.io/badge/version-0.2.0--experimental-blue)
![Status](https://img.shields.io/badge/status-experimental-orange)
![License](https://img.shields.io/badge/license-MIT-green)

Portable encrypted offline snapshot versioning with secure multi-track workflows for disconnected development environments.

**Portable VCS** is an experimental offline-first encrypted snapshot versioning system built for secure portable development workflows.

It is designed as a standalone encrypted snapshot VCS that interoperates with Git when needed — while focusing on portability, encryption, simplified track workflows, and offline resilience.

Portable VCS is not trying to replace Git’s collaborative branching model.  
Instead, it solves a different problem:

> secure encrypted portable version history for offline and disconnected environments.

> [!NOTE]
> This is a tool created for my personal use and is not intended to compete with anything. It's a complement to use with Git.

---

# Why this exists

Portable VCS was built for situations where:

- internet access is unavailable,
- GitHub / GitLab cannot be reached,
- remote repositories are inaccessible,
- encrypted portable backups are required,
- secure offline recovery matters more than distributed collaboration.

Typical examples:

- field/offline development
- travel coding without internet
- secure isolated environments
- air-gapped systems
- removable-drive encrypted repositories
- portable secure development vaults

---

# Why not Git?

Git is excellent for:

- collaboration
- distributed development
- merges and rebases
- branch-heavy workflows

Portable VCS focuses instead on:

- encrypted portable snapshots
- removable-drive repositories
- simplified multi-track workflows
- secure offline recovery
- encrypted version continuity without network dependency

Portable VCS is designed for different priorities than Git.

---

# Important Notice

⚠️ **Experimental Release**

Portable VCS is stable enough for real personal use, but is still evolving.

It is not intended as a production-grade replacement for Git.

Always keep independent backups of critical projects.

---

# What Portable VCS IS

Portable VCS is:

✅ Offline-first  
✅ Encrypted snapshot versioning  
✅ USB/external-drive portable  
✅ Multi-track snapshot workflow  
✅ Secure offline recovery system  
✅ Git interoperable when needed  
✅ Simplified encrypted alternative to branch-heavy workflows

---

# What Portable VCS is NOT

Portable VCS is NOT:

❌ A Git clone  
❌ A distributed collaboration platform  
❌ A merge conflict resolver  
❌ A cloud sync service  
❌ A replacement for team Git workflows

---

# Installation

### Build executable
Windows:
```bash
dart compile exe lib/vcs.dart -o vcs.exe
```

Linux:
```bash
dart compile exe lib/vcs.dart -o vcs
chmod +x vcs
```

### Optional: Add to PATH
Example Windows:
```bash
C:\Tools\vcs\
```

Example Linux:
```bash
sudo cp vcs /usr/bin/
```

Then use globally:
```bash
vcs help
```

---

# Quick Start

### 1. Prepare USB Drive
```bash
vcs setup
```
### 2. Initialize Project
Inside your project folder:
```bash
vcs init
```
### 3. Create Snapshot
```bash
vcs push "Initial snapshot" -a <your-name>
```
### 4. Check Changes
```bash
vcs status
```
### 5. View History
```bash
vcs log
```
<img width="533" height="713" alt="Captura de pantalla 2026-04-14 200227" src="https://github.com/user-attachments/assets/6b18c421-c70e-4715-b58f-f5d3acc7086e" />

### 6. Restore Latest Snapshot
```bash
vcs pull
```

### 7. View Diff
```bash
vcs diff 1776186005719 1776184573501
```
<img width="634" height="938" alt="Captura de pantalla 2026-04-14 200339" src="https://github.com/user-attachments/assets/8246c0a3-8a02-47ea-9af8-5bcb0d20923e" />

### 8. Preview Git Publish Changes
```bash
vcs git-diff --branch main
```
Shows exactly what would change in Git before publishing.

<img width="846" height="987" alt="Captura de pantalla 2026-04-15 205958" src="https://github.com/user-attachments/assets/1e38c28e-a0ed-4bc6-9bf3-a30dc5dc1ccb" />

### 9. View VCS diagnostics
```bash
vcs doctor
```
<img width="428" height="603" alt="Captura de pantalla 2026-04-14 200356" src="https://github.com/user-attachments/assets/184b8914-59f8-4f14-b65d-a98ce773c9f4" />

### 10. View VCS repo stats
```bash
vcs stats
```
<img width="355" height="246" alt="Captura de pantalla 2026-04-14 200413" src="https://github.com/user-attachments/assets/d46becf9-f5f3-41b7-8374-8933fa7d0977" />

### 11. View Track list
```bash
vcs track list
```
<img width="444" height="121" alt="Captura de pantalla 2026-04-15 210828" src="https://github.com/user-attachments/assets/d683b86f-1853-422b-8f5f-2e29a908bca1" />

### 12. View Track switch
```bash
vcs track switch Experimental
```
<img width="705" height="85" alt="Captura de pantalla 2026-04-15 211011" src="https://github.com/user-attachments/assets/ef2f1b48-14fb-446b-a1f4-2a0ac6251f55" />

---
# Web Dashboard (Local UI)
Portable VCS includes a built-in **Web Terminal & Dashboard**, providing an interface to visualize your project history, explore encrypted snapshots, and manage repositories without relying solely on the CLI.

### Launching the Dashboard
To start the local server, run the following command from your project root:
```bash
vcs ui
```
By default, the dashboard will be accessible at `http://localhost:8080`.

### Key Features
* Integrated Web Terminal: Execute any VCS command directly from the browser with full ANSI color support.
* Visual Snapshot Timeline: Browse through your history with a clean UI showing authors, timestamps, and full 13-digit Snapshot IDs.
* Secure Snapshot Inspection: Preview the file tree and content of past snapshots. Data is decrypted on-the-fly in memory using your session password
* Live Repository Context: The dashboard tracks your active branch (track), project metadata, and storage status in real-time.
* New: Smart Split-View Diff: Visualize changes in a side-by-side window.
    * Left Pane: Previous state (Red).
    * Right Pane: Current state (Green).
 
#### Dashboard Preview (Split-View Diff)
The new comparison system automatically aligns code lines to make reviewing complex changes effortless.

<img width="1865" height="999" alt="Captura de pantalla 2026-04-17 175526" src="https://github.com/user-attachments/assets/cb1526a8-8595-499e-bad0-a4b10ff5e197" />

### Manual Confirmation Policy
For security and data integrity, destructive or high-risk operations require manual confirmation. If you trigger these commands from the Web UI, the process will pause and wait for you to confirm the action in your physical system terminal:

| Command | Why it requires terminal confirmation |
|-- |--
| `vcs revert` | To prevent accidental overwriting of your local working directory. |
| `vcs prune` | To ensure you don't accidentally delete multiple historical snapshots. |
| `vcs bind` | To acknowledge differences between local files and the remote repository. |
| `vcs purge` | To prevent the total deletion of remote repository data. |

> [!IMPORTANT]
> If a command appears to "hang" or stay in a loading state within the Web Terminal, check your OS terminal window for a (y/N) prompt.

#### Dashboard Preview
The UI is designed to be lightweight and portable, requiring no external dependencies or internet connection to function.

<img width="1868" height="1038" alt="Captura de pantalla 2026-04-17 011901" src="https://github.com/user-attachments/assets/c72bbe5e-2f3b-4444-8981-5f98001419b3" />

#### Tip: Session Passwords
When prompted for a password in the Web UI, it is used only for the duration of the current command's execution and is never stored on disk or in the server logs, keeping your AES-256 encryption keys completely secure.

# Core Features

### Snapshot System
* Encrypted snapshot creation
* Snapshot restore / revert
* Snapshot integrity verification
* Snapshot history log
* Snapshot diff comparison
* Snapshot pruning

### Track System
* Multiple independent snapshot tracks
* Track switching with optional restore
* Track-specific history isolation
* Safe parallel experimental workflows

### Repository Management
* USB drive portable repositories
* Clone repositories between machines
* Bind folders to existing repositories
* Repository health diagnostics
* Repository statistics

### Git Integration
* Safe Git repository detection
* Git branch-aware publishing
* Dry-run Git publishing
* Safe snapshot-to-Git synchronization
* Protected working tree validation
* Git snapshot preview diff before publish

If no Git remote exists:
* Portable VCS still creates local Git commit
* Push is skipped safely

### Ignore Support
* `.gitignore` compatibility

---

# Git Sync Workflow
Portable VCS safely bridges offline work into Git.

### Preview Git Changes Before Publishing
```bash
vcs git-diff --branch main
```
Compares the latest Portable VCS snapshot against the current Git branch HEAD without modifying anything.

Useful to inspect exactly what would be committed before publish.

### Safe Preview Before Publishing
```bash
vcs publish --branch main --dry-run
```
Shows what would happen without changing anything.

### Prepare Snapshot Into Git Working Tree
```bash
vcs git-prepare --branch main
```
This:
* Validates Git repo
* Checks working tree is clean
* Restore snapshot into working tree
* Does NOT commit or push

### Publish Snapshot to Git
```bash
vcs publish --branch main
```
This safely:
1. validates Git repo
2. checks clean working tree
3. restores latest snapshot
4. stages files
5. creates Git commit
6. pushes to remote branch (if configured)

### Publish Specific Snapshot
```bash
vcs publish 1776279259531 --branch master
```
<img width="644" height="237" alt="Captura de pantalla 2026-04-15 210347" src="https://github.com/user-attachments/assets/1a084f77-20dd-4de9-adab-7f6b82fbfa81" />

### Safety Guarantees for Git Publish

The `publish` command is designed to be the ultimate safe passage between your private sandbox and your official Git history. It treats your Git repository with the highest priority, enforcing strict safety protocols before a single byte is changed.

#### Automatic Fail-Safe Protections
**Portable VCS** will automatically abort the operation if any of these risks are detected:
* **Dirty Working Tree:** If you have uncommitted changes in Git, VCS stops to prevent overwriting your unsaved work.
* **Environment Check:** Operation is blocked if the current directory is not a valid Git repository.
* **Integrity Failure:** If the snapshot is corrupted or decryption fails (wrong password), no files are touched.
* **Remote Awareness:** If no Git remote is found, VCS intelligently completes the Local Commit but skips the push safely.

#### Human-in-the-Loop Verification
You are always in control. Before any action, VCS requires your explicit confirmation:
1. **Restore Check:** Confirming the decryption and file extraction.
2. **Commit Check:** Reviewing the Git commit message and author.
3. **Push Check:** Final "Go/No-Go" before sending data to the remote server.
4. **Safety Backup:** VCS creates a temporary backup of your current state before overwriting files.


### Recommended Publish Flow
Don't guess what you are about to commit. Follow this standard protocol to maintain a 100% clean Git history:

1. The Preview (Visual Diff)
See exactly what changed between your encrypted snapshot and your current Git branch.
```bash
vcs git-diff --branch main
```
2. The Simulation (Dry Run)
Run the entire logic without writing a single file. This checks password validity, Git status, and remote availability.
```bash
vcs publish --branch main --dry-run
```
3. The Execution (Final Publish)
Once verified, perform the actual migration to Git.
```bash
vcs publish --branch main
```

### Why this matters
This flow ensures that when you finally say **"Feature Complete"** in Git, the code is:

✅ Decrypted correctly.  
✅ Verified for integrity.  
✅ Previewed for changes.  
✅ Committed cleanly without WIP noise.

# Main Commands
### 🛠️ Command Reference

### 🛠️ Command Reference

### 🛠️ Command Reference

| Category | Command | Description |
| :--- | :--- | :--- |
| **Setup** | `vcs setup` | Prepare a USB drive or external storage for Vault use. |
| | `vcs init` | Initialize the current project and link it to remote storage. |
| | `vcs list` | List repositories available on the connected USB/storage. |
| | `vcs clone [id] [--into dir]` | Clone a repository from USB into a specific local folder. |
| | `vcs bind [id]` | Bind the current folder to an existing remote repository. |
| **Workflow** | `vcs push "msg" [-a aut] [--track t]` | Create an encrypted snapshot (defaults to active track). |
| | `vcs pull [--track name]` | Restore latest snapshot from a specific or active track. |
| | `vcs revert <snapshot_id>` | Restore a specific snapshot from the active track. |
| | `vcs restore <id> --to <dir>` | Restore a specific snapshot into another folder. |
| **Inspection & UI** | `vcs ui` | **Launch the local web dashboard** for visual history & diffs. |
| | `vcs status` | Compare tree against latest of the **active track**. |
| | `vcs diff [id]` | Compare working tree vs latest or specific ID in **active track**. |
| | `vcs diff <id1> <id2>` | Compare two specific snapshots using split-view. |
| | `vcs log [--track name]` | Show history (Standard/Full options available). |
| | `vcs show <id>` | Show detailed information about a snapshot in **active track**. |
| | `vcs tree [id]` | Show file tree structure of a snapshot in **active track**. |
| **Tracks** | `vcs track list` | List all available history tracks. |
| | `vcs track current` | Show the name of the currently active track. |
| | `vcs track create <name>` | Create a new independent development lane. |
| | `vcs track switch <name>` | Switch the active track (with optional tree restore). |
| | `vcs track delete <name>` | Remove an existing non-active track and its history. |
| **Git Bridge** | `vcs git-diff [id] --branch b` | Preview changes between snapshot and Git branch. |
| | `vcs git-prepare [id] --branch b` | Restore snapshot into Git tree and stage files. |
| | `vcs publish [id] --branch b` | **Atomic move:** Restore, commit, and push to Git safely. |
| **Maintenance**| `vcs verify <id\|--all>` | Run SHA-256 integrity checks on one or all snapshots. |
| | `vcs doctor` | Run repository diagnostics and health checks. |
| | `vcs stats` | Show size, snapshot count, and storage statistics. |
| | `vcs prune --keep N` | Keep only the newest N snapshots in the **active track**. |
| | `vcs clear-history` | Wipe all snapshots for the **active track**. |
| | `vcs purge` | Permanently delete the project from the Vault. |
| **General** | `vcs version` | Show current Portable VCS version. |
| | `vcs help` | Show this help message. |

# Encryption
Snapshots are encrypted locally before storage.
Your project files are never uploaded anywhere by Portable VCS.
Everything remains local unless you explicitly publish to Git remote.

# .gitignore Support
Portable VCS automatically respects existing `.gitignore` rules.

Example:
```gitignore
.git/
node_modules/
build/
.dart_tool/
```

# Example Real Workflow
1. Create a "Safe Lab" in VCS
Don't create a Git branch yet. Just create a track in your encrypted Vault.
```bash
vcs track create "new-auth-logic"
```
2. Iterate and Fail (Dirty Work)
Save snapshots as you break things. If you mess up, `vcs pull` and try again.
```bash
vcs push "First attempt: broken"
vcs push "Second attempt: compiling but buggy"
vcs push "Final attempt: logic verified ✅"
```

3. Move to Production (Git)
Only once the code in your VCS track is perfect, you "promote" it to Git.
```bash
vcs publish --branch main
```
Result: Git only sees one perfect commit. All the failures stay hidden and encrypted in your Vault.

# Parallel Reality Workflow (Multi-Track
Tracks allow you to maintain multiple independent versions of your project. You can jump between a risky experiment and a stable fix in seconds, keeping your Git working tree ready for what matters.

### Scenario: The "What If" Experiment
You have a crazy idea for a refactor, but you don't want to mess up your current stable progress or create a messy Git branch.

1. Create and enter your sandbox:
```bash
vcs track create Brainstorming
vcs track switch Brainstorming
```

2. Work and fail safely:
```bash
# Save a snapshot of your risky changes
vcs push "Total refactor of the UI core"
```

3. Instant context switch:
Suddenly, a bug appears in your main version. You need to go back instantly.
```bash
vcs track switch main
vcs pull  # Restores your stable code in 1 second
```

4. Fix and Secure:
```bash
vcs push "Critical hotfix for production" -a "Nooch98"
```

5. Back to the experiment:
Now that the crisis is over, go back to your "Brainstorming" track exactly where you left off.
```bash
vcs track switch Brainstorming
vcs pull
```

# Current Limitations
* Tracks exist, but advanced branch merge workflows are not supported yet
* No merge conflict resolution
* Full snapshot storage (not incremental yet)
* Large projects consume more storage
* Single-user focused design

# Stability Status
### Experimental but usable
Recommended for:
* personal use
* offline development backup
* technical evaluation
* Git companion workflows

Not yet recommended for:
* enterprise production teams
* critical multi-user workflows

# Testing Coverage

Currently tested:

✅ init

✅ push

✅ status

✅ revert

✅ clone

✅ prune

✅ verify

✅ doctor

✅ stats

✅ bind

✅ .gitignore exclusion

✅ Git publish safety flow

# Roadmap

Planned improvements:

* - [ ] smarter line-ending normalization in Git diff
* - [ ] incremental snapshots
* - [ ] advanced track merging
* - [ ] track diff comparison
* - [ ] conflict-aware Git publish
* - [ ] export/import bundle mode
* - [ ] snapshot compression optimization

# Contributing

Feedback, testing reports, and bug reports are welcome.
Real-world usage feedback is especially valuable.

# License

MIT License

# Author

Created by Nooch98  
Portable offline encrypted multi-track snapshot versioning for disconnected environments.
