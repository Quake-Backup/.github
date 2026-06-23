#!/usr/bin/bash
# repo-sync.sh — Sincronización paralela de forks de organización
#
# Variables de entorno (útiles para CI/CD):
#   SYNC_OWNER, SYNC_THREADS, SYNC_SKIP_FILE, GH_TOKEN
#
# Uso: ./repo-sync.sh [--owner org] [--threads N] [--skip-file path] [--dry-run]

set -euo pipefail

# --- Config ---
owner="${SYNC_OWNER:-Quake-Backup}"
per_page="${SYNC_PER_PAGE:-100}"
max_pages="${SYNC_MAX_PAGES:-10}"
threads="${SYNC_THREADS:-10}"
skip_file="${SYNC_SKIP_FILE:-./.sync-skip.conf}"
auto_skip_gone=false
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)         owner="$2";         shift 2 ;;
        --threads)       threads="$2";       shift 2 ;;
        --skip-file)     skip_file="$2";     shift 2 ;;
        --auto-skip-gone) auto_skip_gone=true; shift ;;
        --dry-run)       dry_run=true;       shift ;;
        --help|-h)       sed -n '2,7p' "$0"; exit 0 ;;
        *) echo "Error: opción '$1' desconocida. Usa --help." >&2; exit 1 ;;
    esac
done

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

log_dir=$(mktemp -d -t sync-gh-XXXXXXXXXX)
trap 'rm -rf "$log_dir"' EXIT

# --- Skip list ---
declare -A skip_map
if [[ -f "$skip_file" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -z "$line" ]] && continue
        skip_map["$line"]=1
    done < "$skip_file"
fi

# --- Paginación ---
echo "Obteniendo forks de $owner..."
repos=()
page=1
while [[ $page -le $max_pages ]]; do
    json=$(gh repo list "$owner" --limit "$per_page" --page "$page" --fork --json nameWithOwner 2>/dev/null)
    count=$(echo "$json" | jq '. | length')
    [[ $count -eq 0 ]] && break
    while IFS= read -r r; do
        repos+=("$r")
    done < <(echo "$json" | jq -r '.[].nameWithOwner')
    ((page++))
done

total=${#repos[@]}
if [[ $total -eq 0 ]]; then
    echo "No se encontraron forks en $owner."
    exit 0
fi

active=()
skip_hits=()
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

# --- Worker ---
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

# --- Reporte ---
echo ""
echo "=========================================="
echo "            SYNC REPORT"
echo "=========================================="

ok=0
fail=()
skip_new=()
conflict=()

for f in "$log_dir"/*.result; do
    [[ -f "$f" ]] || continue
    read -r status < "$f"
    read -r repo < "$f"
    err=$(tail -1 "$f" 2>/dev/null || true)
    [[ "$err" == "$status" || "$err" == "$repo" ]] && err=""

    case "$status" in
        OK)       ((ok++)) ;;
        FAIL)     fail+=("$repo") ;;
        SKIP)     skip_new+=("$repo") ;;
        CONFLICT) conflict+=("$repo") ;;
    esac

    # Guardar en archivos planos para post-procesamiento
    echo "$repo" >> "$log_dir/${status}.txt"
done

echo "✅ Exitosos: $ok"

if [[ ${#skip_new[@]} -gt 0 ]]; then
    echo ""
    echo "⏭️  Saltados (upstream eliminado): ${#skip_new[@]}"
    for repo in "${skip_new[@]}"; do
        echo "  - $repo"
    done
    echo "  → Agrégalos a $skip_file para silenciar permanentemente."

    if $auto_skip_gone; then
        for repo in "${skip_new[@]}"; do
            echo "# $(date +%Y-%m-%d) - upstream no encontrado" >> "$skip_file"
            echo "$repo" >> "$skip_file"
        done
        echo "  → Añadidos automáticamente a $skip_file"
    fi
fi

if [[ ${#conflict[@]} -gt 0 ]]; then
    echo ""
    echo "⚠️  Conflictos (historial reescrito): ${#conflict[@]}"
    for repo in "${conflict[@]}"; do
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
    for repo in "${fail[@]}"; do
        echo "  - $repo (revisa logs en $log_dir)"
    done
fi

echo ""
echo "------------------------------------------"
echo " Resumen: $ok OK · ${#skip_new[@]} saltados"
echo "          ${#conflict[@]} conflictos · ${#fail[@]} fallos"
echo "=========================================="
