#!/usr/bin/env bash
#
# Migrate a legacy docs/spec.md to workflow metadata schema 1.
#
# The command is a dry run unless --force is supplied. A backup is created
# before the project-owned spec is replaced.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_PATH=""
CONFIG_PATH=""
BACKUP_PATH=""
FORCE=0

usage() {
    cat <<'EOF'
Usage: ./scripts/migrate-spec.sh [--force] [--spec-path PATH] [--repo-root PATH]
       [--config-path PATH] [--backup-path PATH]

Without --force the command reports what it would migrate and leaves the spec
untouched.
EOF
}

while (($# > 0)); do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        --spec-path)
            [[ $# -ge 2 ]] || { echo '[FAIL] --spec-path requires a value.'; exit 1; }
            SPEC_PATH="$2"
            shift 2
            ;;
        --repo-root)
            [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 1; }
            REPO_ROOT="$2"
            shift 2
            ;;
        --config-path)
            [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 1; }
            CONFIG_PATH="$2"
            shift 2
            ;;
        --backup-path)
            [[ $# -ge 2 ]] || { echo '[FAIL] --backup-path requires a value.'; exit 1; }
            BACKUP_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[FAIL] Unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$SPEC_PATH" ]]; then
    SPEC_PATH="$REPO_ROOT/docs/spec.md"
fi
if [[ -z "$CONFIG_PATH" ]]; then
    CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"
fi
if [[ ! -f "$SPEC_PATH" ]]; then
    echo "[FAIL] docs/spec.md not found at: $SPEC_PATH"
    exit 1
fi

CONTENT="$(tr -d '\r' < "$SPEC_PATH")"

frontmatter() {
    awk '
        NR == 1 && $0 == "---" { inside = 1; next }
        inside && $0 == "---" { found = 1; exit }
        inside { print }
        END { if (!found) exit 2 }
    ' <<< "$CONTENT"
}

if FRONT_MATTER="$(frontmatter 2>/dev/null)"; then
    if grep -Eq '^sdlc_schema:[[:space:]]*1[[:space:]]*$' <<< "$FRONT_MATTER"; then
        echo '[PASS] docs/spec.md already uses workflow metadata schema 1.'
        exit 0
    fi
    echo '[FAIL] docs/spec.md has front matter but not the supported sdlc_schema: 1 format.'
    exit 1
fi

normalize_path() {
    local value="$1"
    value="${value//\\//}"
    while [[ "$value" == ./* ]]; do
        value="${value#./}"
    done
    printf '%s' "$value"
}

get_legacy_scalar() {
    local section="$1"
    awk -v section="$section" '
        $0 == "## " section { found = 1; next }
        found && $0 ~ /^`[^`]+`$/ { gsub(/`/, ""); print; exit }
    ' <<< "$CONTENT"
}

get_section_body() {
    local section="$1"
    awk -v section="$section" '
        $0 == "## " section { found = 1; next }
        found && ($0 ~ /^## / || $0 ~ /^---[[:space:]]*$/) { exit }
        found { print }
    ' <<< "$CONTENT"
}

meaningful_text() {
    awk '
        BEGIN { comment = 0 }
        /<!--/ { comment = 1 }
        !comment { print }
        /-->/ { comment = 0 }
    ' | sed -E \
        -e '/^_.*(PM|Designer|Architect|Reviewer|QA).*_$/d' \
        -e 's/\((PM|Designer|Architect|Reviewer|QA)[^)]*\)//g' \
        -e '/^[[:space:]]*```/d' \
        -e '/^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]*$/d' \
        -e 's/^[[:space:]]*-?[[:space:]]*$//g' \
        -e '/^[[:space:]]*$/d' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

CURRENT_PHASE="$(get_legacy_scalar 'Current State' | tr -d '\r')"
case "$CURRENT_PHASE" in
    GATHERING_REQS|DESIGN|PLANNING|CODING|REVIEW|TESTING|DEPLOYMENT_READINESS|DONE) ;;
    *)
        echo "[FAIL] Legacy Current State '$CURRENT_PHASE' is missing or invalid."
        exit 1
        ;;
esac

REVIEW_CYCLE="$(get_legacy_scalar 'Review Cycle' | tr -d '\r')"
if [[ -z "$REVIEW_CYCLE" ]]; then
    REVIEW_CYCLE=0
fi
if ! [[ "$REVIEW_CYCLE" =~ ^[0-3]$ ]]; then
    echo "[FAIL] Legacy Review Cycle '$REVIEW_CYCLE' must be an integer from 0 through 3."
    exit 1
fi

DESIGN_REQUIRED=false
if [[ -n "$(get_section_body 'Design' | meaningful_text)" ]]; then
    DESIGN_REQUIRED=true
fi

DEPLOYMENT_READINESS_ENABLED=false
if [[ -f "$CONFIG_PATH" ]] && grep -Eq '^[[:space:]]*deployment_readiness_gate:[[:space:]]*true[[:space:]]*$' "$CONFIG_PATH"; then
    DEPLOYMENT_READINESS_ENABLED=true
fi
AI_GOVERNANCE_ENABLED=false
if [[ -f "$CONFIG_PATH" ]] && awk '/^ai_governance:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found && /^[[:space:]]+enabled:[[:space:]]*true[[:space:]]*$/{print "true"; exit}' "$CONFIG_PATH" | grep -q true; then
    AI_GOVERNANCE_ENABLED=true
fi
AI_LIFECYCLE_ENABLED=false
if [[ -f "$CONFIG_PATH" ]] && awk '/^ai_lifecycle:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found && /^[[:space:]]+enabled:[[:space:]]*true[[:space:]]*$/{print "true"; exit}' "$CONFIG_PATH" | grep -q true; then
    AI_LIFECYCLE_ENABLED=true
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$BACKUP_PATH" ]]; then
    BACKUP_RELATIVE=".sdlc/migrations/spec.md.${TIMESTAMP}.legacy.bak"
    BACKUP_PATH="$REPO_ROOT/$BACKUP_RELATIVE"
elif [[ "$BACKUP_PATH" = /* ]]; then
    case "$BACKUP_PATH" in
        "$REPO_ROOT"/*) BACKUP_RELATIVE="${BACKUP_PATH#"$REPO_ROOT"/}" ;;
        *) echo '[FAIL] Backup path must be inside the repository root.'; exit 1 ;;
    esac
else
    BACKUP_RELATIVE="$(normalize_path "$BACKUP_PATH")"
    [[ "$BACKUP_RELATIVE" != /* && "$BACKUP_RELATIVE" != ../* && "$BACKUP_RELATIVE" != */../* && "$BACKUP_RELATIVE" != '..' ]] || { echo '[FAIL] Backup path must be relative and safe.'; exit 1; }
    BACKUP_PATH="$REPO_ROOT/$BACKUP_RELATIVE"
fi

FILE_BLOCK="$(awk '
    $0 == "## File Structure" { section = 1; next }
    section && /^```/ { fence += 1; if (fence == 1) next; if (fence == 2) exit }
    section && fence == 1 { print }
' <<< "$CONTENT")"
declare -a PLANNED_FILES=()
while IFS= read -r line; do
    path="$(normalize_path "$line")"
    [[ -n "$path" && "$path" != \#* && "$path" != //* ]] || continue
    if [[ "$path" == */ ]]; then
        echo "[WARN] Skipping legacy directory scope entry '$path'; add exact files after migration."
        continue
    fi
    if [[ "$path" == /* || "$path" =~ ^[A-Za-z]:/ || "$path" =~ (^|/)\.\.(/|$) ]]; then
        echo "[WARN] Skipping unsafe legacy scope entry '$path'."
        continue
    fi
    duplicate=0
    for existing in "${PLANNED_FILES[@]}"; do
        [[ "$existing" == "$path" ]] && duplicate=1
    done
    if (( duplicate == 0 )); then
        PLANNED_FILES+=("$path")
    fi
done <<< "$FILE_BLOCK"

if (( FORCE == 0 )); then
    echo "[INFO] Legacy state: $CURRENT_PHASE; review cycle: $REVIEW_CYCLE; design required: $DESIGN_REQUIRED; readiness enabled: $DEPLOYMENT_READINESS_ENABLED"
    echo "[INFO] Exact planned files recovered: ${#PLANNED_FILES[@]}"
    echo "[INFO] Backup: $BACKUP_PATH"
    echo '[BLOCKED] Migration is a dry run. Re-run with --force to create the backup and update docs/spec.md.'
    exit 2
fi
if [[ -e "$BACKUP_PATH" ]]; then
    echo "[FAIL] Backup path already exists: $BACKUP_PATH"
    exit 1
fi
backup_directory="$(dirname "$BACKUP_PATH")"
[[ ! -f "$backup_directory" ]] || { echo "[FAIL] Backup directory path is a file: $backup_directory"; exit 1; }
mkdir -p "$backup_directory"

metadata='---\n'
metadata+="sdlc_schema: 1\n"
metadata+="current_phase: $CURRENT_PHASE\n"
metadata+="design_required: $DESIGN_REQUIRED\n"
metadata+="deployment_readiness_enabled: $DEPLOYMENT_READINESS_ENABLED\n"
metadata+="ai_governance_enabled: $AI_GOVERNANCE_ENABLED\n"
metadata+="ai_lifecycle_enabled: $AI_LIFECYCLE_ENABLED\n"
metadata+='security_gate_enabled: false\n'
metadata+="review_cycle: $REVIEW_CYCLE\n"
metadata+='revision_commit_sha: ""\n'
metadata+='revision_tree_digest: ""\n'
metadata+='last_transition_from: legacy\n'
metadata+="last_transition_to: $CURRENT_PHASE\n"
metadata+="last_transition_timestamp: $TIMESTAMP\n"
metadata+='last_transition_actor: migration\n'
metadata+="last_transition_evidence: $BACKUP_RELATIVE\n"
if (( ${#PLANNED_FILES[@]} == 0 )); then
    metadata+='planned_files: []\n'
else
    metadata+='planned_files:\n'
    for path in "${PLANNED_FILES[@]}"; do
        metadata+="  - $path\n"
    done
fi
metadata+='approved_globs: []\n'
for gate in requirements config install design planning build security review test lint type_check package deploy sbom smoke_test rollback release deployment_readiness ai_governance ai_lifecycle; do
    metadata+="gate_${gate}_command: \"\"\n"
    metadata+="gate_${gate}_commit_sha: \"\"\n"
    metadata+="gate_${gate}_tree_digest: \"\"\n"
    metadata+="gate_${gate}_timestamp: \"\"\n"
    metadata+="gate_${gate}_exit_code: \"\"\n"
    metadata+="gate_${gate}_result: NOT_RUN\n"
    metadata+="gate_${gate}_evidence: \"\"\n"
done
metadata+='---\n'

temporary_spec="$SPEC_PATH.migration.tmp"
printf '%b%s\n' "$metadata" "$CONTENT" > "$temporary_spec"
cp "$SPEC_PATH" "$BACKUP_PATH"
mv "$temporary_spec" "$SPEC_PATH"
echo '[PASS] Migrated docs/spec.md to workflow metadata schema 1.'
