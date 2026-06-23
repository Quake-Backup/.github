# Quake-Backup/.github

Meta-repository containing the organization's automation.

For public information about the organization, see [profile/README.md](profile/README.md).

---

## Contents

| File | Purpose |
|---|---|
| `repo-sync.sh` | Main fork synchronization script |
| `scripts/update-sync-issue.sh` | Keeps the tracking issue up to date |
| `.github/workflows/sync.yml` | Weekly GitHub Actions workflow |
| `.sync-skip.conf` | List of repos the sync should ignore |
| `.sync-report.md` | Markdown report generated on each run (gitignored) |

---

## How it works

Every Monday at 12:00 UTC the workflow runs automatically (it can also be triggered manually from the Actions tab):

1. **Sync** — `repo-sync.sh` lists the forks and calls `gh repo sync` in parallel (10 threads). Results are classified as **OK / SKIP / CONFLICT / FAIL**
2. **Step summary** — the report shows up in the Actions UI
3. **Update issue** — edits the `[bot] Quake-Backup fork sync report` issue
4. **Commit skip-list** — if `--auto-skip-gone` added repos, commits automatically

<!-- TODO: add a Performance section (repo count, thread count, expected runtime) -->

---

## How to add a repo to the skip-list

Edit `.sync-skip.conf` and add a line in `Owner/Repo` format:

```
# .sync-skip.conf - Repos to skip during sync
Quake-Backup/q2pro
Quake-Backup/another-orphan-repo
```

Alternatively, let the script do it automatically with `--auto-skip-gone` (which the workflow does).

---

## How to run the sync locally

Requirement: `gh` CLI authenticated (`gh auth login`).

```bash
./repo-sync.sh --dry-run              # see what would be synced
./repo-sync.sh                        # run for real
./repo-sync.sh --owner AnotherOrg     # different org
./repo-sync.sh --threads 20           # more parallelism
./repo-sync.sh --report-file out.md   # write markdown report
```

---

## How to read the tracking issue

The `[bot] Quake-Backup fork sync report` issue always shows the current state:

- **OK** — all good, no action needed
- **SKIP** — upstream deleted. If the repo no longer applies, leave it in the skip-list
- **CONFLICT** — history rewritten. Options: `gh repo sync <repo> --force` (destructive), add it to the skip-list, or manual backup + force
- **FAIL** — unclassified error. Check the run log in Actions

---

## Required secret

`GH_PAT` — Personal Access Token with `Contents: Read and write` across the org. Configure it in Settings → Secrets and variables → Actions of this repo.

---

## Reporting problems

Open an Issue in this repo.
