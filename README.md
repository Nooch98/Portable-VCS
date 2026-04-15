# Portable VCS

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

# Main Use Case

### Offline workflow:

```bash
vcs push "offline work before travel"
```
### Later when internet returns:
```bash
vcs publish --branch main
```
This safely restores the latest offline snapshot into your Git repo and publishes it into Git locally or upstream if a remote exists.

---

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

# Installation

### Build executable
```bash
dart compile exe lib/vcs.dart -o vcs.exe
```
### Optional: Add to PATH
Example Windows:
```bash
C:\Tools\vcs\
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

Portable VCS will refuse publish if:

* current folder is not Git repo
* Git working tree has uncommitted changes
* snapshot is invalid
* snapshot decryption fails

if remote does not exist:
* publish continues as local git commit only

Before publish it always:

- ✅ asks confirmation before restore
- ✅ asks confirmation before commit
- ✅ asks confirmation before push
- ✅ creates backup before overwrite

# Recommended Safe Git Publish Flow

Before publishing offline work into Git:

```bash
vcs git-diff --branch main
vcs publish --branch main --dry-run
vcs publish --branch main
```

This gives you:

1. Exact Git diff preview
2. Safe dry-run validation
3. Final confirmed publish

# Main Commands
| Command | Description |
| --- | --- |
| `setup` | Prepare USB drive |
| `init` |	Initialize project |
| `list` |	List repositories on USB |
| `clone <repo_id>` |	Clone repo from USB |
| `bind <repo_id>` |	Bind folder to existing repo |
| `status` |	Show pending changes |
| `push "msg"` |	Save encrypted snapshot |
| `log` |	Show snapshot history |
| `show <id>` |	Show snapshot details |
| `diff [id1] [id2]` |	Compare snapshots |
| `pull` |	Restore latest snapshot |
| `revert <id>` |	Restore specific snapshot |
| `restore <id>` |	Restore snapshot elsewhere |
| `verify <id> [--all]` | Verify snapshot integrity |
| `doctor` |	Diagnose repository health |
| `stats` |	Show repository stats |
| `prune` |	Delete old snapshots |
| `clear-history` |	Remove snapshots |
| `purge` |	Delete repo from USB |
| `git-prepare` |	Prepare snapshot into Git tree |
| `publish` |	Commit + push snapshot into Git |
| `tree` | Show file tree of latest snapshot |
| `git-diff` | Compare snapshot against Git branch HEAD |
| `track list` | List all tracks |
| `track create <name>` | Create a new track |
| `track switch <name>` | Switch active track |
| `track delete <name>` | Delete a track |
| `version` | Show current Portable VCS version |

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
vcs.exe
```

# Example Real Workflow
### Online:
```bash
git commit -m "feature complete"
git push origin main
```

### Offline:
```bash
vcs push "offline backup while traveling"
```

### Back online:
```bash
vcs publish --branch main
```

# Track Workflow Example
Each track keeps independent snapshot history and can be restored separately.
```bash
vcs track create Experimental
vcs track switch Experimental
vcs push "try new refactor"

vcs track switch main
vcs push "stable release work"
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

* smarter line-ending normalization in Git diff
* incremental snapshots
* advanced track merging
* track diff comparison
* conflict-aware Git publish
* export/import bundle mode
* snapshot compression optimization

# Contributing

Feedback, testing reports, and bug reports are welcome.
Real-world usage feedback is especially valuable.

# License

MIT License

# Author

Created by Nooch98  
Portable offline encrypted multi-track snapshot versioning for disconnected environments.
