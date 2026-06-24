#!/usr/bin/bash
# scripts/commit-to-data-branch.sh
# Commits files to the data/sync-state branch using a worktree.
# Creates the branch as orphan on first run.
#
# Uso: ./scripts/commit-to-data-branch.sh <src>[:<dst>] [...] -- <message>
#   src = path to source file (relative or absolute)
#   dst = path in the data branch (default: basename of src)
# All source files must exist.

set -euo pipefail

DATA_BRANCH="data/sync-state"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

# Parse args: file args until '--', then message
file_args=()
message=""
parsing_files=true
for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
        parsing_files=false
        continue
    fi
    if $parsing_files; then
        file_args+=("$arg")
    else
        if [[ -z "$message" ]]; then
            message="$arg"
        else
            message="$message $arg"
        fi
    fi
done

message="${message# }"

if [[ -z "$message" ]]; then
    echo "Error: commit message required (use -- to separate files from message)" >&2
    exit 1
fi

if [[ ${#file_args[@]} -eq 0 ]]; then
    echo "Error: at least one file required" >&2
    exit 1
fi

# Parse src:dst pairs
declare -a sources=()
declare -a dests=()
for arg in "${file_args[@]}"; do
    if [[ "$arg" == *:* ]]; then
        sources+=("${arg%%:*}")
        dests+=("${arg#*:}")
    else
        sources+=("$arg")
        dests+=("$(basename "$arg")")
    fi
done

# Check all source files exist
for src in "${sources[@]}"; do
    if [[ ! -f "$src" ]]; then
        echo "Error: source file not found: $src" >&2
        exit 1
    fi
done

# Configure git identity if not set
if ! git config user.name >/dev/null 2>&1; then
    git config user.name "sync-bot"
    git config user.email "bot@quake-backup"
fi

# Ensure data branch exists
if git ls-remote --heads origin "$DATA_BRANCH" 2>/dev/null | grep -q "$DATA_BRANCH"; then
    echo "Branch $DATA_BRANCH existe, usando worktree..."

    worktree_dir="/tmp/data-wt-$$"
    git worktree add "$worktree_dir" "$DATA_BRANCH"

    for i in "${!sources[@]}"; do
        local_dest="$worktree_dir/${dests[$i]}"
        mkdir -p "$(dirname "$local_dest")"
        cp "${sources[$i]}" "$local_dest"
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

    git switch --orphan "$DATA_BRANCH"
    git rm -rf . 2>/dev/null || true

    for i in "${!sources[@]}"; do
        mkdir -p "$(dirname "${dests[$i]}")"
        cp "${sources[$i]}" "${dests[$i]}"
    done

    git add .
    git commit -m "$message"
    git push -u origin "$DATA_BRANCH"
    git switch main
    echo "Push OK a $DATA_BRANCH (creada)"
fi
