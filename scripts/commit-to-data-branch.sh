#!/usr/bin/bash
# scripts/commit-to-data-branch.sh
# Commits files to the data/sync-state branch using a worktree.
# Creates the branch as orphan on first run.
#
# Uso: ./scripts/commit-to-data-branch.sh <file1> [file2 ...] -- <message>
# All files must exist in the current working directory.

set -euo pipefail

DATA_BRANCH="data/sync-state"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

# Parse args: files until '--', then message
files=()
message=""
parsing_files=true
for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
        parsing_files=false
        continue
    fi
    if $parsing_files; then
        files+=("$arg")
    else
        if [[ -z "$message" ]]; then
            message="$arg"
        else
            message="$message $arg"
        fi
    fi
done

if [[ -z "$message" ]]; then
    echo "Error: commit message required (use -- to separate files from message)" >&2
    exit 1
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "Error: at least one file required" >&2
    exit 1
fi

# Check all source files exist
for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: source file not found: $f" >&2
        exit 1
    fi
done

# Configure git identity if not set (needed in fresh checkouts)
if ! git config user.name >/dev/null 2>&1; then
    git config user.name "sync-bot"
    git config user.email "bot@quake-backup"
fi

# Ensure data branch exists
if git ls-remote --heads origin "$DATA_BRANCH" 2>/dev/null | grep -q "$DATA_BRANCH"; then
    echo "Branch $DATA_BRANCH existe, usando worktree..."

    worktree_dir="/tmp/data-wt-$$"
    git worktree add "$worktree_dir" "$DATA_BRANCH"

    for f in "${files[@]}"; do
        cp "$f" "$worktree_dir/$f"
    done

    cd "$worktree_dir"
    git add .
    if git diff --cached --quiet; then
        echo "No hay cambios para commitear"
    else
        git commit -m "$message"
        git push origin "$DATA_BRANCH"
        echo "Push OK a $DATA_BRANCH"
    fi
    cd "$GITHUB_WORKSPACE"
    git worktree remove "$worktree_dir" --force
else
    echo "Branch $DATA_BRANCH no existe, creando orphan branch..."

    # Create orphan branch
    git switch --orphan "$DATA_BRANCH"
    git rm -rf . 2>/dev/null || true

    for f in "${files[@]}"; do
        cp "$GITHUB_WORKSPACE/$f" "$f"
    done

    git add .
    git commit -m "$message"
    git push -u origin "$DATA_BRANCH"
    git switch main
    echo "Push OK a $DATA_BRANCH (creada)"
fi
