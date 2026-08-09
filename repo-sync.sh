#!/usr/bin/env bash
# repo-sync.sh — Fork sync and org monitoring
#
# Modes:
#   sync (default)        — Sync forks and classify results
#   --check-deletions      — Detect deletions/additions vs snapshot
#
# Environment variables:
#   SYNC_OWNER, SYNC_THREADS, SYNC_SKIP_FILE, GH_TOKEN,
#   SYNC_REPORT_FILE, SYNC_TZ, GITHUB_RUN_URL
#
# Sync usage:
#   ./repo-sync.sh [--owner org] [--threads N] [--skip-file path]
#                  [--report-file path] [--auto-skip-gone] [--dry-run]
#
# Check-deletions usage:
#   ./repo-sync.sh --check-deletions
#                   [--snapshot-input path] [--snapshot-output path]
#                   [--deletions-log path]
#                   [--deletions-report path] [--additions-report path]

set -euo pipefail
set -E
trap 'echo "ERROR: line $LINENO, exit $?, command: $BASH_COMMAND" >&2' ERR

# --- Small helpers ---
gh_retry() {
    # Usage: gh_retry <max_attempts> <cmd...>
    local max_attempts=${1:-3}; shift
    local attempt=1
    local delay=2
    while true; do
        if "$@"; then
            return 0
        fi
        if (( attempt >= max_attempts )); then
            return 1
        fi
        sleep $((delay * attempt))
        attempt=$((attempt + 1))
    done
}

# --- Timing helpers ---
get_duration_seconds() {
    local start_time=$1
    local end_time=$2
    echo $(( (end_time - start_time) ))
}

format_duration() {
    local seconds=$1
    local hours=$(( seconds / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$(( seconds % 60 ))
    
    if (( hours > 0 )); then
        printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
    elif (( minutes > 0 )); then
        printf "%dm %ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

# --- Config ---
owner="${SYNC_OWNER:-Quake-Backup}"
threads="${SYNC_THREADS:-10}"
skip_file="${SYNC_SKIP_FILE:-./.sync-skip.conf}"
report_file="${SYNC_REPORT_FILE:-}"
tz="${SYNC_TZ:-America/Santiago}"
auto_skip_gone=false
dry_run=false
reset_snapshot=false
mode="sync"
snapshot_input="./.sync-snapshot.txt"
snapshot_output="./.sync-snapshot.txt"
deletions_log="./.sync-deleted.txt"
deletions_report=""
additions_report=""
sync_timeout="${SYNC_TIMEOUT:-300}"
sync_max_retries="${SYNC_MAX_RETRIES:-1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)         owner="$2";         shift 2 ;;
        --threads)       threads="$2";       shift 2 ;;
        --skip-file)     skip_file="$2";     shift 2 ;;
        --report-file)   report_file="$2";   shift 2 ;;
        --check-deletions) mode="check-deletions"; shift ;;
        --snapshot-input)  snapshot_input="$2";  shift 2 ;;
        --snapshot-output) snapshot_output="$2"; shift 2 ;;
        --deletions-log)   deletions_log="$2";   shift 2 ;;
        --deletions-report) deletions_report="$2"; shift 2 ;;
        --additions-report) additions_report="$2"; shift 2 ;;
        --auto-skip-gone) auto_skip_gone=true; shift ;;
        --reset-snapshot) reset_snapshot=true; shift ;;
        --dry-run)       dry_run=true;       shift ;;
        --sync-timeout)  sync_timeout="$2";  shift 2 ;;
        --max-retries)   sync_max_retries="$2"; shift 2 ;;
        --help|-h)       sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Error: unknown option '$1'. Use --help." >&2; exit 1 ;;
    esac
done

# --- Sanitize numeric inputs ---
if ! [[ "$threads" =~ ^[0-9]+$ ]] || [[ $threads -lt 1 ]]; then
    echo "WARNING: invalid threads='$threads' — falling back to 10"
    threads=10
fi
if ! [[ "$sync_timeout" =~ ^[0-9]+$ ]] || [[ $sync_timeout -lt 1 ]]; then
    echo "WARNING: invalid sync_timeout='$sync_timeout' — falling back to 300"
    sync_timeout=300
fi
if ! [[ "$sync_max_retries" =~ ^[0-9]+$ ]] || [[ $sync_max_retries -lt 0 ]]; then
    echo "WARNING: invalid sync_max_retries='$sync_max_retries' — falling back to 1"
    sync_max_retries=1
fi

# --- Pre-checks ---
for cmd in gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is not installed. Please install it (gh: https://cli.github.com/, jq: https://jqlang.github.io/jq/)." >&2
        exit 1
    fi
done

if ! gh auth status; then
    echo "Error: Not authenticated with GitHub. Set GH_TOKEN or run 'gh auth login'." >&2
    exit 1
fi

# --- Snapshot helpers ---
parse_snapshot() {
    local file="$1"
    local -n out=$2

    out=()
    [[ -f "$file" ]] || return 0

    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -z "$line" ]] && continue
        out+=("$line")
    done < "$file"
}

snapshot_timestamp() {
    local file="$1"
    [[ -f "$file" ]] || { echo ""; return 0; }
    sed -n 's/^# snapshot:[[:space:]]*//p' "$file" | head -1
}

write_snapshot_file() {
    local file="$1"
    shift
    local -a repos=("$@")
    local timestamp
    timestamp=$(TZ="$tz" date '+%Y-%m-%dT%H:%M:%S%z')

    {
        echo "# snapshot: $timestamp"
        if [[ ${#repos[@]} -gt 0 ]]; then
            printf '%s\n' "${repos[@]}"
        fi
    } > "$file"
}

append_deletions_log() {
    local file="$1"
    shift
    local -a deleted=("$@")
    local timestamp_human
    timestamp_human=$(TZ="$tz" date '+%Y-%m-%d %H:%M %Z')

    [[ -f "$file" ]] || {
        {
            echo "# Repos detected as deleted"
            echo "# Format: YYYY-MM-DD HH:MM TZ	Owner/Repo"
        } > "$file"
    }

    for repo in "${deleted[@]}"; do
        echo "${timestamp_human}	${repo}" >> "$file"
    done
}

# --- Repo listing with dynamic pagination + retry/backoff ---
list_repos() {
    local -a repos=()

    echo "Fetching repos (gh pages internally up to --limit)..." >&2

    local json
    if ! json=$(gh repo list "$owner" --limit 1000 --fork \
                  --json nameWithOwner 2>&1); then
        echo "  gh repo list failed, retrying with backoff..." >&2
        if ! json=$(gh_retry 3 gh repo list "$owner" --limit 1000 --fork \
                      --json nameWithOwner 2>&1); then
            echo "Error: 'gh repo list' failed for $owner after retries." >&2
            echo "  $json" >&2
            return 1
        fi
    fi

    # Sanitize and collect results
    while IFS= read -r r; do
        [[ -n "$r" ]] && repos+=("$r")
    done <<< "$(printf '%s' "$json" | jq -r '.[].nameWithOwner')"

    echo "Loaded ${#repos[@]} repos" >&2
    printf '%s\n' "${repos[@]}"
}

# --- Compute diff ---
compute_diff() {
    local -n _prev=$1
    local -n _curr=$2
    local -n _del=$3
    local -n _add=$4

    declare -A _curr_set
    for r in "${_curr[@]}"; do
        _curr_set["$r"]=1
    done

    _del=()
    for r in "${_prev[@]}"; do
        if [[ -z "${_curr_set[$r]:-}" ]]; then
            _del+=("$r")
        fi
    done

    declare -A _prev_set
    for r in "${_prev[@]}"; do
        _prev_set["$r"]=1
    done

    _add=()
    for r in "${_curr[@]}"; do
        if [[ -z "${_prev_set[$r]:-}" ]]; then
            _add+=("$r")
        fi
    done
}

# --- Mode: check-deletions ---
run_check_deletions() {
    local start_time
    start_time=$(date +%s)

    local -a previous=()
    if $reset_snapshot; then
        echo "RESET SNAPSHOT: ignoring previous snapshot, writing new baseline"
        previous=()
        deletions_log=""
        deletions_report=""
        additions_report=""
    else
        parse_snapshot "$snapshot_input" previous
    fi

    local -a current=()
    if ! mapfile -t current < <(list_repos); then
        echo "Error: failed to load current repos from gh" >&2
        return 1
    fi

    local -a deleted=() added=()
    compute_diff previous current deleted added

    if ! write_snapshot_file "$snapshot_output" "${current[@]}"; then
        echo "Error: failed to write snapshot to $snapshot_output" >&2
        return 1
    fi

    if [[ ${#deleted[@]} -gt 0 ]]; then
        append_deletions_log "$deletions_log" "${deleted[@]}"
    fi

    local prev_ts=""
    if ! prev_ts=$(snapshot_timestamp "$snapshot_input"); then
        echo "Error: failed to read snapshot timestamp from $snapshot_input" >&2
        return 1
    fi
    local now_ts
    if ! now_ts=$(TZ="$tz" date '+%Y-%m-%dT%H:%M:%S%z'); then
        echo "Error: failed to get current timestamp" >&2
        return 1
    fi
    local now_human
    if ! now_human=$(TZ="$tz" date '+%Y-%m-%d %H:%M %Z'); then
        echo "Error: failed to get human timestamp" >&2
        return 1
    fi

    # Console report
    echo ""
    echo "=========================================="
    echo "       DELETION / ADDITION CHECK"
    echo "=========================================="
    if [[ ${#previous[@]} -eq 0 ]]; then
        echo "Baseline established. ${#current[@]} repos tracked."
        echo "Snapshot: $snapshot_output"
        echo "Deletion log: $deletions_log"
    else
        echo "Previous snapshot: $prev_ts"
        echo "Current snapshot:  $now_ts"
        echo "Current repos:     ${#current[@]}"
        echo "Deleted:           ${#deleted[@]}"
        echo "Added:             ${#added[@]}"
        echo ""
        if [[ ${#deleted[@]} -gt 0 ]]; then
            echo "🗑️  Deleted repos:"
            for r in "${deleted[@]}"; do
                echo "  - $r"
            done
        fi
        if [[ ${#added[@]} -gt 0 ]]; then
            echo ""
            echo "✨ Added repos:"
            for r in "${added[@]}"; do
                echo "  + $r"
            done
        fi
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration
    duration=$(get_duration_seconds "$start_time" "$end_time")
    echo "Duration: $(format_duration "$duration")"
    echo "=========================================="

    # Markdown report: deletions
    if [[ -n "$deletions_report" ]]; then
        {
            echo "# 🗑️ Fork deletions report"
            echo ""
            echo "**Last check:** $now_human"
            if [[ -n "$prev_ts" ]]; then
                echo "**Previous snapshot:** $prev_ts"
            else
                echo "**Previous snapshot:** _(none — first run)_"
            fi
            echo ""
            if [[ ${#previous[@]} -eq 0 ]]; then
                echo "## Summary"
                echo ""
                echo "ℹ️ **Baseline established.** ${#current[@]} repos tracked. Future runs will be able to detect deletions."
            else
                echo "## Summary"
                echo ""
                echo "- 🗑️ **${#deleted[@]}** repos deleted since last check"
                echo "- 📦 Current total: **${#current[@]}** repos"
                if [[ ${#deleted[@]} -gt 0 ]]; then
                    echo ""
                    echo "## Deleted repos"
                    echo ""
                    for r in "${deleted[@]}"; do
                        echo "- [$r](https://github.com/$r)"
                    done
                fi
            fi
        } > "$deletions_report"
    fi

    # Markdown report: additions
    if [[ -n "$additions_report" ]]; then
        {
            echo "# ✨ Fork additions report"
            echo ""
            echo "**Last check:** $now_human"
            if [[ -n "$prev_ts" ]]; then
                echo "**Previous snapshot:** $prev_ts"
            else
                echo "**Previous snapshot:** _(none — first run)_"
            fi
            echo ""
            if [[ ${#previous[@]} -eq 0 ]]; then
                echo "## Summary"
                echo ""
                echo "ℹ️ **Baseline established.** ${#current[@]} repos tracked. Future runs will be able to detect additions."
            else
                echo "## Summary"
                echo ""
                echo "- ✨ **${#added[@]}** repos added since last check"
                echo "- 📦 Current total: **${#current[@]}** repos"
                if [[ ${#added[@]} -gt 0 ]]; then
                    echo ""
                    echo "## Added repos"
                    echo ""
                    for r in "${added[@]}"; do
                        echo "- [$r](https://github.com/$r)"
                    done
                fi
            fi
        } > "$additions_report"
    fi
}

# --- Mode: sync (default) ---
ok=0
fail=()      # formato: "repo|err"
skip_new=()  # formato: "repo|err"
conflict=()  # formato: "repo|err"
wf_scope=()  # formato: "repo|err"

write_report() {
    [[ -z "$report_file" ]] && return 0

    local timestamp
    timestamp=$(TZ="$tz" date '+%Y-%m-%d %H:%M %Z')
    local run_url="${GITHUB_RUN_URL:-}"

    {
        echo "# 🔄 Fork sync report"
        echo ""
        echo "**Last run:** $timestamp"
        if [[ -n "$run_url" ]]; then
            echo ""
            echo "**Workflow run:** [link]($run_url)"
        fi
        echo ""
        echo "## Summary"
        echo ""
        echo "- ✅ **$ok** synced"
        echo "- ⏭️ **${#skip_new[@]}** skipped (deleted upstream)"
        echo "- ⚠️ **${#conflict[@]}** conflicts (rewritten history)"
        echo "- 🔐 **${#wf_scope[@]}** workflow-scope failures"
        echo "- ❌ **${#fail[@]}** unclassified failures"
        echo ""

        if [[ ${#skip_new[@]} -gt 0 ]]; then
            echo "## Skipped repos"
            echo ""
            for entry in "${skip_new[@]}"; do
                IFS='|' read -r repo err <<< "$entry"
                echo "- [$repo](https://github.com/$repo)"
                [[ -n "$err" ]] && echo "  - $err"
            done
            echo ""
        fi

        if [[ ${#conflict[@]} -gt 0 ]]; then
            echo "## Conflicts"
            echo ""
            for entry in "${conflict[@]}"; do
                IFS='|' read -r repo err <<< "$entry"
                echo "- [$repo](https://github.com/$repo)"
                [[ -n "$err" ]] && echo "  - $err"
            done
            echo ""
        fi

        if [[ ${#wf_scope[@]} -gt 0 ]]; then
            echo "## Workflow-scope failures"
            echo ""
            echo "_Upstream changed workflow files, which require the 'workflow' scope/permission to merge._"
            echo ""
            for entry in "${wf_scope[@]}"; do
                IFS='|' read -r repo err <<< "$entry"
                echo "- [$repo](https://github.com/$repo)"
                [[ -n "$err" ]] && echo "  - $err"
                echo "  - _Fix: grant 'workflow' scope to GH_PAT or enable 'workflows: write'._"
            done
            echo ""
        fi

        if [[ ${#fail[@]} -gt 0 ]]; then
            echo "## Failures"
            echo ""
            for entry in "${fail[@]}"; do
                IFS='|' read -r repo err <<< "$entry"
                echo "- [$repo](https://github.com/$repo)"
                [[ -n "$err" ]] && echo "  - $err"
            done
            echo ""
        fi

        if [[ $ok -gt 0 && ${#skip_new[@]} -eq 0 && ${#conflict[@]} -eq 0 && ${#fail[@]} -eq 0 && ${#wf_scope[@]} -eq 0 ]]; then
            echo "_All repos synced successfully._ 🎉"
            echo ""
        fi
    } > "$report_file"

    echo ""
    echo ""
    echo "Markdown report written to: $report_file"
}

run_sync() {
    local start_time
    start_time=$(date +%s)
    
    log_dir=$(mktemp -d -t sync-gh-XXXXXXXXXX)
    trap 'rm -rf "$log_dir"' EXIT

    declare -A skip_map
    if [[ -f "$skip_file" ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line//[[:space:]]/}"
            [[ -z "$line" ]] && continue
            skip_map["$line"]=1
        done < "$skip_file"
    fi

    echo "Getting forks of $owner..."
    local -a repos=()
    if ! mapfile -t repos < <(list_repos); then
        echo "Error: failed to list repos from gh" >&2
        exit 1
    fi

    local total=${#repos[@]}
    if [[ $total -eq 0 ]]; then
        echo "No forks found in $owner."
        write_report
        exit 0
    fi

    local -a active=() skip_hits=()
    for repo in "${repos[@]}"; do
        if [[ -v skip_map["$repo"] ]]; then
            skip_hits+=("$repo")
        else
            active+=("$repo")
        fi
    done

    echo "Total: $total | To sync: ${#active[@]} | Skipped: ${#skip_hits[@]}"
    $dry_run && { echo "[DRY-RUN] Aborting."; exit 0; }
    echo "Threads: $threads | Logs: $log_dir"
    echo "Sync timeout: ${sync_timeout}s | Max retries: ${sync_max_retries}"
    echo "=========================================="

    sync_one() {
        local repo="$1"
        local log_dir="$2"
        local safe="${repo//\//_}"
        local log="$log_dir/${safe}.log"
        local res="$log_dir/${safe}.result"
        local attempt=0

        while [[ $attempt -le $sync_max_retries ]]; do
            if timeout "$sync_timeout" gh repo sync "$repo" >"$log" 2>&1; then
                printf 'OK\n%s\n' "$repo" > "$res"
                return 0
            fi
            
            ((attempt++))
            if [[ $attempt -le $sync_max_retries ]]; then
                echo "Retry attempt $attempt for $repo..." >> "$log"
                sleep 5
            fi
        done

        local err
        err=$(tail -1 "$log" 2>/dev/null || echo "unknown")

        if echo "$err" | grep -qiE "workflow scope|workflow changes|require the workflow scope|permission to merge"; then
            printf 'WORKFLOW_SCOPE\n%s\n%s\n' "$repo" "$err" > "$res"
        elif echo "$err" | grep -qiE "not found|404|could not find|does not exist|removed|deleted|upstream.*not"; then
            printf 'SKIP\n%s\n%s\n' "$repo" "$err" > "$res"
        elif echo "$err" | grep -qiE "not fast.forward|merge conflict|history diverged|ahead of|behind|force"; then
            printf 'CONFLICT\n%s\n%s\n' "$repo" "$err" > "$res"
        else
            printf 'FAIL\n%s\n%s\n' "$repo" "$err" > "$res"
        fi
    }
    export -f sync_one
    export LOG_DIR="$log_dir"
    export SYNC_TIMEOUT="$sync_timeout"
    export SYNC_MAX_RETRIES="$sync_max_retries"

    printf '%s\n' "${active[@]}" | \
        xargs -P "$threads" -I {} bash -c 'sync_one "$1" "$LOG_DIR"' _ {}

    echo ""
    echo "=========================================="
    echo "            SYNC REPORT"
    echo "=========================================="

    for f in "$log_dir"/*.result; do
        [[ -f "$f" ]] || continue
        local -a lines
        mapfile -t lines < "$f"
        local status="${lines[0]:-}"
        local repo="${lines[1]:-}"
        local err="${lines[2]:-}"
        [[ "$err" == "$status" || "$err" == "$repo" ]] && err=""

        case "$status" in
            OK)              ok=$((ok + 1)) ;;
            FAIL)            fail+=("${repo}|${err}") ;;
            SKIP)            skip_new+=("${repo}|${err}") ;;
            CONFLICT)        conflict+=("${repo}|${err}") ;;
            WORKFLOW_SCOPE)  wf_scope+=("${repo}|${err}") ;;
        esac

        echo "$repo" >> "$log_dir/${status}.txt"
    done

    echo "✅ Successful: $ok"

    if [[ ${#skip_new[@]} -gt 0 ]]; then
        echo ""
        echo "⏭️  Skipped (deleted upstream): ${#skip_new[@]}"
        for entry in "${skip_new[@]}"; do
            IFS='|' read -r repo _ <<< "$entry"
            echo "  - $repo"
        done
        echo "  → Add them to $skip_file to silence permanently."

        if $auto_skip_gone; then
            for entry in "${skip_new[@]}"; do
                IFS='|' read -r repo _ <<< "$entry"
                echo "# $(TZ="$tz" date +%Y-%m-%d) - upstream not found" >> "$skip_file"
                echo "$repo" >> "$skip_file"
            done
            echo "  → Auto-added to $skip_file"
        fi
    fi

    if [[ ${#conflict[@]} -gt 0 ]]; then
        echo ""
        echo "⚠️  Conflicts (rewritten history): ${#conflict[@]}"
        for entry in "${conflict[@]}"; do
            IFS='|' read -r repo _ <<< "$entry"
            echo "  - $repo"
        done
        echo "  → Possible solutions (per repo):"
        echo "     1. gh repo sync <repo> --force  (loses local changes)"
        echo "     2. Add it temporarily to $skip_file"
        echo "     3. Make manual backup (create branch) before forcing"
    fi

    if [[ ${#wf_scope[@]} -gt 0 ]]; then
        echo ""
        echo "🔐 Workflow-scope failures: ${#wf_scope[@]}"
        for entry in "${wf_scope[@]}"; do
            IFS='|' read -r repo _ <<< "$entry"
            echo "  - $repo (upstream changed workflows)"
        done
        echo "  → Fix: grant the token the 'workflow' scope/permission"
        echo "     (Settings → Secrets → GH_PAT must include workflow scope, or"
        echo "     enable 'workflows: write' in the workflow permissions)."
    fi

    if [[ ${#fail[@]} -gt 0 ]]; then
        echo ""
        echo "❌ Unclassified failures: ${#fail[@]}"
        for entry in "${fail[@]}"; do
            IFS='|' read -r repo _ <<< "$entry"
            echo "  - $repo (check logs in $log_dir)"
        done
    fi

    echo ""
    echo "------------------------------------------"
    echo " Summary: $ok OK · ${#skip_new[@]} skipped"
    echo "          ${#conflict[@]} conflicts · ${#wf_scope[@]} workflow-scope · ${#fail[@]} failures"
    
    local end_time
    end_time=$(date +%s)
    local duration
    duration=$(get_duration_seconds "$start_time" "$end_time")
    echo " Duration: $(format_duration "$duration")"
    echo "=========================================="

    write_report
}

# --- Dispatch ---
if [[ "$mode" == "check-deletions" ]]; then
    run_check_deletions
else
    run_sync
fi
