#!/usr/bin/bash
# scripts/update-sync-issue.sh
# Crea o edita el issue de tracking con el reporte de sync.
#
# Uso: ./scripts/update-sync-issue.sh <report-file> <target-repo>
# Args:
#   report-file  - path al archivo markdown con el reporte
#   target-repo  - repo donde crear/editar el issue (e.g. Quake-Backup/.github)

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Uso: $0 <report-file> <target-repo>" >&2
    exit 1
fi

report_file="$1"
target_repo="$2"
issue_title="[bot] Quake-Backup fork sync report"
label="sync-report"

if [[ ! -f "$report_file" ]]; then
    echo "Error: $report_file no existe." >&2
    exit 1
fi

echo "Asegurando label '$label' en $target_repo..."
if ! gh label list --repo "$target_repo" --json name \
        | jq -e --arg l "$label" '.[] | select(.name==$l)' >/dev/null 2>&1; then
    gh label create "$label" --repo "$target_repo" \
        --color "C5DEF5" \
        --description "Fork sync automation report" \
        --force 2>/dev/null || true
fi

echo "Buscando issue existente con título '$issue_title'..."
existing=$(gh issue list --repo "$target_repo" --state all --json number,title --limit 1000 \
    | jq -r --arg t "$issue_title" '.[] | select(.title==$t) | .number' \
    | head -1 || true)

if [[ -n "$existing" ]]; then
    echo "Editando issue #$existing..."
    gh issue edit "$existing" --repo "$target_repo" --body-file "$report_file"

    state=$(gh issue view "$existing" --repo "$target_repo" --json state -q '.state')
    if [[ "$state" == "CLOSED" ]]; then
        echo "Reabriendo issue #$existing (estaba cerrado)..."
        gh issue reopen "$existing" --repo "$target_repo"
    fi
    echo "Issue #$existing actualizado."
else
    echo "Creando issue nuevo..."
    new_url=$(gh issue create --repo "$target_repo" \
        --title "$issue_title" \
        --body-file "$report_file" \
        --label "$label")
    echo "Issue creado: $new_url"
fi
