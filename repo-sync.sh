#!/usr/bin/bash
# repo-sync.sh — Sincronización y monitoreo de forks de organización
#
# Modos:
#   sync (default)        — Sincroniza forks y clasifica resultados
#   --check-deletions      — Detecta deleciones/adiciones vs snapshot
#
# Variables de entorno:
#   SYNC_OWNER, SYNC_THREADS, SYNC_SKIP_FILE, GH_TOKEN,
#   SYNC_REPORT_FILE, SYNC_TZ, GITHUB_RUN_URL
#
# Uso sync:
#   ./repo-sync.sh [--owner org] [--threads N] [--skip-file path]
#                  [--report-file path] [--auto-skip-gone] [--dry-run]
#
# Uso check-deletions:
#   ./repo-sync.sh --check-deletions
#                   [--snapshot-input path] [--snapshot-output path]
#                   [--deletions-log path]
#                   [--deletions-report path] [--additions-report path]
#                   [--skip-file path]

set -euo pipefail

# --- Config ---
owner="${SYNC_OWNER:-Quake-Backup}"
per_page="${SYNC_PER_PAGE:-100}"
max_pages="${SYNC_MAX_PAGES:-10}"
threads="${SYNC_THREADS:-10}"
skip_file="${SYNC_SKIP_FILE:-./.sync-skip.conf}"
report_file="${SYNC_REPORT_FILE:-}"
tz="${SYNC_TZ:-America/Santiago}"
auto_skip_gone=false
dry_run=false
mode="sync"
snapshot_input="./.sync-snapshot.txt"
snapshot_output="./.sync-snapshot.txt"
deletions_log="./.sync-deleted.txt"
deletions_report=""
additions_report=""

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
        --dry-run)       dry_run=true;       shift ;;
        --help|-h)       sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Error: opción '$1' desconocida. Usa --help." >&2; exit 1 ;;
    esac
done

# --- Pre-checks ---
for cmd in gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd no está instalado." >&2
        exit 1
    fi
done

if ! gh auth status &>/dev/null; then
    echo "Error: No autenticado en GitHub. Configura GH_TOKEN o ejecuta 'gh auth login'." >&2
    exit 1
fi

# --- Snapshot helpers ---
parse_snapshot() {
    local file="$1"
    local -n out=$2

    out=()
    [[ -f "$file" ]] || return 1

    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -z "$line" ]] && continue
        out+=("$line")
    done < "$file"
}

snapshot_timestamp() {
    local file="$1"
    [[ -f "$file" ]] || { echo ""; return; }
    grep -m1 '^# snapshot:' "$file" | sed 's/^# snapshot:[[:space:]]*//'
}

write_snapshot_file() {
    local file="$1"
    shift
    local -a repos=("$@")
    local timestamp
    timestamp=$(TZ="$tz" date '+%Y-%m-%dT%H:%M:%S%z')

    {
        echo "# snapshot: $timestamp"
        printf '%s\n' "${repos[@]}"
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

# --- Repo listing ---
list_repos() {
    local -a repos=()
    local page=1

    while [[ $page -le $max_pages ]]; do
        local json
        json=$(gh repo list "$owner" --limit "$per_page" --page "$page" \
                  --fork --json nameWithOwner 2>/dev/null)
        local count
        count=$(echo "$json" | jq '. | length')
        [[ $count -eq 0 ]] && break
        while IFS= read -r r; do
            repos+=("$r")
        done < <(echo "$json" | jq -r '.[].nameWithOwner')
        ((page++))
    done

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
        [[ -z "${_curr_set[$r]:-}" ]] && _del+=("$r")
    done

    declare -A _prev_set
    for r in "${_prev[@]}"; do
        _prev_set["$r"]=1
    done

    _add=()
    for r in "${_curr[@]}"; do
        [[ -z "${_prev_set[$r]:-}" ]] && _add+=("$r")
    done
}

# --- Mode: check-deletions ---
run_check_deletions() {
    local -a previous=()
    parse_snapshot "$snapshot_input" previous

    local -a current
    mapfile -t current < <(list_repos)

    local -a deleted=() added=()
    compute_diff previous current deleted added

    write_snapshot_file "$snapshot_output" "${current[@]}"

    if [[ ${#deleted[@]} -gt 0 ]]; then
        append_deletions_log "$deletions_log" "${deleted[@]}"
    fi

    local prev_ts
    prev_ts=$(snapshot_timestamp "$snapshot_input")
    local now_ts
    now_ts=$(TZ="$tz" date '+%Y-%m-%dT%H:%M:%S%z')
    local now_human
    now_human=$(TZ="$tz" date '+%Y-%m-%d %H:%M %Z')

    # Reporte consola
    echo ""
    echo "=========================================="
    echo "       DELETION / ADDITION CHECK"
    echo "=========================================="
    if [[ ${#previous[@]} -eq 0 ]]; then
        echo "Baseline established. ${#current[@]} repos catalogados."
        echo "Snapshot: $snapshot_output"
        echo "Deletion log: $deletions_log"
    else
        echo "Previous snapshot: $prev_ts"
        echo "Current snapshot:  $now_ts"
        echo "Repos actuales: ${#current[@]}"
        echo "Eliminados:       ${#deleted[@]}"
        echo "Agregados:        ${#added[@]}"
        echo ""
        if [[ ${#deleted[@]} -gt 0 ]]; then
            echo "🗑️  Repos eliminados:"
            for r in "${deleted[@]}"; do
                echo "  - $r"
            done
        fi
        if [[ ${#added[@]} -gt 0 ]]; then
            echo ""
            echo "✨ Repos agregados:"
            for r in "${added[@]}"; do
                echo "  + $r"
            done
        fi
    fi
    echo "=========================================="

    # Reporte markdown: deletions
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
                echo "ℹ️ **Baseline established.** ${#current[@]} repos catalogados. Próximas ejecuciones podrán detectar deleciones."
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

    # Reporte markdown: additions
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
                echo "ℹ️ **Baseline established.** ${#current[@]} repos catalogados. Próximas ejecuciones podrán detectar adiciones."
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

        if [[ $ok -gt 0 && ${#skip_new[@]} -eq 0 && ${#conflict[@]} -eq 0 && ${#fail[@]} -eq 0 ]]; then
            echo "_All repos synced successfully._ 🎉"
            echo ""
        fi
    } > "$report_file"

    echo ""
    echo "Reporte markdown escrito en: $report_file"
}

run_sync() {
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

    echo "Obteniendo forks de $owner..."
    local -a repos=()
    local page=1
    while [[ $page -le $max_pages ]]; do
        local json
        json=$(gh repo list "$owner" --limit "$per_page" --page "$page" \
                  --fork --json nameWithOwner 2>/dev/null)
        local count
        count=$(echo "$json" | jq '. | length')
        [[ $count -eq 0 ]] && break
        while IFS= read -r r; do
            repos+=("$r")
        done < <(echo "$json" | jq -r '.[].nameWithOwner')
        ((page++))
    done

    local total=${#repos[@]}
    if [[ $total -eq 0 ]]; then
        echo "No se encontraron forks en $owner."
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

    echo "Total: $total | A sincronizar: ${#active[@]} | Saltados: ${#skip_hits[@]}"
    $dry_run && { echo "[DRY-RUN] Abortando."; exit 0; }
    echo "Hilos: $threads | Logs: $log_dir"
    echo "=========================================="

    sync_one() {
        local repo="$1"
        local log_dir="$2"
        local safe="${repo//\//_}"
        local log="$log_dir/${safe}.log"
        local res="$log_dir/${safe}.result"

        if timeout 120 gh repo sync "$repo" >"$log" 2>&1; then
            printf 'OK\n%s\n' "$repo" > "$res"
            return 0
        fi

        local err
        err=$(tail -1 "$log" 2>/dev/null || echo "unknown")

        if echo "$err" | grep -qiE "not found|404|could not find|does not exist|removed|deleted|upstream.*not"; then
            printf 'SKIP\n%s\n%s\n' "$repo" "$err" > "$res"
        elif echo "$err" | grep -qiE "not fast.forward|merge conflict|history diverged|ahead of|behind|force"; then
            printf 'CONFLICT\n%s\n%s\n' "$repo" "$err" > "$res"
        else
            printf 'FAIL\n%s\n%s\n' "$repo" "$err" > "$res"
        fi
    }
    export -f sync_one
    export LOG_DIR="$log_dir"

    printf '%s\n' "${active[@]}" | \
        xargs -P "$threads" -I {} bash -c 'sync_one "$1" "$LOG_DIR"' _ {}

    echo ""
    echo "=========================================="
    echo "            SYNC REPORT"
    echo "=========================================="

    for f in "$log_dir"/*.result; do
        [[ -f "$f" ]] || continue
        read -r status < "$f"
        read -r repo < "$f"
        err=$(tail -1 "$f" 2>/dev/null || true)
        [[ "$err" == "$status" || "$err" == "$repo" ]] && err=""

        case "$status" in
            OK)       ((ok++)) ;;
            FAIL)     fail+=("${repo}|${err}") ;;
            SKIP)     skip_new+=("${repo}|${err}") ;;
            CONFLICT) conflict+=("${repo}|${err}") ;;
        esac

        echo "$repo" >> "$log_dir/${status}.txt"
    done

    echo "✅ Exitosos: $ok"

    if [[ ${#skip_new[@]} -gt 0 ]]; then
        echo ""
        echo "⏭️  Saltados (upstream eliminado): ${#skip_new[@]}"
        for entry in "${skip_new[@]}"; do
            IFS='|' read -r repo _ <<< "$entry"
            echo "  - $repo"
        done
        echo "  → Agrégalos a $skip_file para silenciar permanentemente."

        if $auto_skip_gone; then
            for entry in "${skip_new[@]}"; do
                IFS='|' read -r repo _ <<< "$entry"
                echo "# $(TZ="$tz" date +%Y-%m-%d) - upstream no encontrado" >> "$skip_file"
                echo "$repo" >> "$skip_file"
            done
            echo "  → Añadidos automáticamente a $skip_file"
        fi
    fi

    if [[ ${#conflict[@]} -gt 0 ]]; then
        echo ""
        echo "⚠️  Conflictos (historial reescrito): ${#conflict[@]}"
        for entry in "${conflict[@]}"; do
            IFS='|' read -r repo _ <<< "$entry"
            echo "  - $repo"
        done
        echo "  → Soluciones posibles (por cada repo):"
        echo "     1. gh repo sync <repo> --force  (pierde cambios locales)"
        echo "     2. Agregarlo temporalmente a $skip_file"
        echo "     3. Hacer backup manual (crear branch) antes de forzar"
    fi

    if [[ ${#fail[@]} -gt 0 ]]; then
        echo ""
        echo "❌ Fallos no clasificados: ${#fail[@]}"
        for entry in "${fail[@]}"; do
            IFS='|' read -r repo _ <<< "$entry"
            echo "  - $repo (revisa logs en $log_dir)"
        done
    fi

    echo ""
    echo "------------------------------------------"
    echo " Resumen: $ok OK · ${#skip_new[@]} saltados"
    echo "          ${#conflict[@]} conflictos · ${#fail[@]} fallos"
    echo "=========================================="

    write_report
}

# --- Dispatch ---
if [[ "$mode" == "check-deletions" ]]; then
    run_check_deletions
else
    run_sync
fi
