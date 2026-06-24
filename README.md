# Quake-Backup/.github

Meta-repository containing the organization's automation.

For public information about the organization, see [profile/README.md](profile/README.md).

---

## Contents

| File | Purpose |
|---|---|
| `repo-sync.sh` | Main fork synchronization + deletion check script |
| `scripts/commit-to-data-branch.sh` | Commits data files to the `data/sync-state` branch |
| `scripts/update-sync-issue.sh` | Keeps the sync tracking issue up to date |
| `scripts/update-deletions-issue.sh` | Keeps the deletions tracking issue up to date |
| `scripts/update-additions-issue.sh` | Keeps the additions tracking issue up to date |
| `.github/workflows/sync.yml` | Weekly sync workflow (Mondays 12:00 UTC) |
| `.github/workflows/deletion-check.yml` | Daily deletion/addition check (~12:00 Chile time) |
| `.sync-skip.conf` | List of repos the sync should ignore |
| `.sync-report.md` | Markdown report from sync (gitignored) |
| `.deletions-report.md` | Markdown report from deletions check (gitignored) |
| `.additions-report.md` | Markdown report from additions check (gitignored) |

---

## How it works

There are two automated workflows, plus a data branch where state lives.

### Weekly sync (Mondays 12:00 UTC)

`sync.yml` runs `repo-sync.sh` in **sync mode**:

1. **Pull skip-list** from `data/sync-state` (the latest version, may have new auto-additions)
2. **Sync** — `gh repo sync` in parallel (10 threads). Results classified as **OK / SKIP / CONFLICT / FAIL**
3. **Step summary** — report visible in Actions UI
4. **Update issue** — edits the `[bot] Quake-Backup fork sync report` issue (label: `sync-report`)
5. **Commit skip-list** — if `--auto-skip-gone` added repos, commits the updated `.sync-skip.conf` to `data/sync-state`

### Daily check (~12:00 Chile time)

`deletion-check.yml` runs `repo-sync.sh` in **check-deletions mode**:

1. **Pull previous snapshot** from `data/sync-state` (the `.sync-snapshot.txt` file)
2. **Pull existing deletion log** from `data/sync-state` (the `.sync-deleted.txt` file)
3. **Compare** — current org repos vs the snapshot. Detects **DELETED** (was in snapshot, not in current) and **ADDED** (in current, not in snapshot)
4. **Step summary** — both reports visible in Actions UI
5. **Update issues** — edits `[bot] Quake-Backup fork deletions` (red `deletion-report`) and `[bot] Quake-Backup fork additions` (green `addition-report`)
6. **Commit** — writes the new snapshot and appends to the deletion log, pushes to `data/sync-state`

### The `data/sync-state` branch

This is a **data-only branch**. It contains:

| File | Format | Purpose |
|---|---|---|
| `.sync-snapshot.txt` | `# snapshot: <ISO timestamp>` then one repo per line | Current state of org's forks |
| `.sync-deleted.txt` | Append-only log with timestamp + repo | History of detected deletions |
| `.sync-skip.conf` | Same as main's format | Latest skip-list, auto-updated by sync |

The branch is **read-only for humans** — the workflows write to it automatically. On first run, it's created as an orphan branch (no history from main) so it stays clean.

<!-- TODO: add a Performance section (repo count, thread count, expected runtime) -->

---

## How to add a repo to the skip-list

There are two ways:

**Manually** — edit `.sync-skip.conf` in main:

```
# .sync-skip.conf - Repos to skip during sync
Quake-Backup/q2pro
Quake-Backup/another-orphan-repo
```

**Automatically** — when a repo is detected as `SKIP` (upstream gone), the sync adds it to `.sync-skip.conf` automatically with `--auto-skip-gone`. The next workflow run commits the updated file to `data/sync-state`.

---

## How to run locally

Requirement: `gh` CLI authenticated (`gh auth login`).

**Sync mode:**
```bash
./repo-sync.sh --dry-run              # see what would be synced
./repo-sync.sh                        # run for real
./repo-sync.sh --owner AnotherOrg     # different org
./repo-sync.sh --threads 20           # more parallelism
./repo-sync.sh --report-file out.md   # write markdown report
./repo-sync.sh --auto-skip-gone       # auto-add SKIP repos to skip-list
```

**Check-deletions mode:**
```bash
./repo-sync.sh --check-deletions \
  --snapshot-input .sync-snapshot.txt \
  --snapshot-output /tmp/new-snapshot.txt \
  --deletions-log /tmp/new-deletions.txt \
  --deletions-report /tmp/deletions.md \
  --additions-report /tmp/additions.md
```

---

## How to read the tracking issues

Three issues, one per concern:

### `[bot] Quake-Backup fork sync report` (label: `sync-report`, blue)

- **OK** — all good, no action needed
- **SKIP** — upstream deleted. The repo is added to skip-list automatically
- **CONFLICT** — history rewritten. Options: `gh repo sync <repo> --force` (destructive), add it to the skip-list, or manual backup + force
- **FAIL** — unclassified error. Check the run log in Actions

### `[bot] Quake-Backup fork deletions` (label: `deletion-report`, red)

Lists repos that disappeared from the org between checks. Useful for catching legal takedowns, forced removals, or transfers.

### `[bot] Quake-Backup fork additions` (label: `addition-report`, green)

Lists repos added to the org between checks.

### First run

On the first run of the daily check, no snapshot exists, so the issues say "Baseline established" with the current repo count. Detection of changes starts from the second run onwards.

---

## Required secrets

- `GH_PAT` — Personal Access Token with `Contents: Read and write` across the org. Used by sync mode for `gh repo sync` against all 283 forks.
- `GITHUB_TOKEN` — auto-generated by Actions. Used for issue operations and commits to the data branch.

Configure `GH_PAT` in Settings → Secrets and variables → Actions of this repo.

---

## Reporting problems

Open an Issue in this repo.
