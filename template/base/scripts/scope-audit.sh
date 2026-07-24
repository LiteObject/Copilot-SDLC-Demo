#!/usr/bin/env bash
#
# Compare changed files with the explicit planned_files scope in docs/spec.md.
#
# Exact paths are the default. Glob patterns are accepted only when a matching
# approved_globs record contains pattern, justification, approver, revision,
# and timestamp fields separated by '|'. Directory entries such as src/ are
# rejected.
#
# Exit codes:
#   0 - scope is clean
#   1 - scope creep or missing files detected
#   2 - the scope plan could not be parsed or is invalid

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/feature-context.sh"
. "$SCRIPT_DIR/contract-parser.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_PATH=""
FEATURE_ID=""
SPEC_RELATIVE_PATH='docs/spec.md'
BASE_REF='HEAD'

usage() {
    cat <<'EOF'
Usage: ./scripts/scope-audit.sh [BASE_REF] [--feature-id ID] [--spec-path PATH] [--repo-root PATH]
EOF
}

while (($# > 0)); do
    case "$1" in
        --spec-path)
            [[ $# -ge 2 ]] || { echo '[ERROR] --spec-path requires a value.'; exit 2; }
            SPEC_PATH="$2"
            shift 2
            ;;
        --feature-id)
            [[ $# -ge 2 ]] || { echo '[ERROR] --feature-id requires a value.'; exit 2; }
            FEATURE_ID="$2"
            shift 2
            ;;
        --repo-root)
            [[ $# -ge 2 ]] || { echo '[ERROR] --repo-root requires a value.'; exit 2; }
            REPO_ROOT="$2"
            shift 2
            ;;
        --base-ref)
            [[ $# -ge 2 ]] || { echo '[ERROR] --base-ref requires a value.'; exit 2; }
            BASE_REF="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            usage >&2
            exit 2
            ;;
        *)
            if [[ "$BASE_REF" != 'HEAD' ]]; then
                echo "[ERROR] Unexpected argument: $1"
                exit 2
            fi
            BASE_REF="$1"
            shift
            ;;
    esac
done

if ! resolve_feature_context "$REPO_ROOT" "$SPEC_PATH" "$FEATURE_ID" ''; then exit 2; fi
if [[ ! -f "$SPEC_PATH" ]]; then
    echo "[ERROR] docs/spec.md not found at: $SPEC_PATH"
    exit 2
fi

CONTENT="$(tr -d '\r' < "$SPEC_PATH")"
if ! read_canonical_contract "$SPEC_PATH" spec-front-matter; then exit 2; fi
trap cleanup_canonical_contract EXIT

declare -A META=()
declare -a PLANNED_FILES=()
declare -a APPROVED_GLOBS=()
declare -a APPROVED_SHARED_FILES=()

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

while IFS= read -r -d '' key; do
    if value="$(canonical_contract_query "$key" scalar 2>/dev/null)"; then META["$key"]="$value"; else META["$key"]=''; fi
done < <(canonical_contract_query '' keys-nul 2>/dev/null || true)
while IFS= read -r -d '' item; do PLANNED_FILES+=("$item"); done < <(canonical_contract_query planned_files nul 2>/dev/null || true)
while IFS= read -r -d '' item; do APPROVED_GLOBS+=("$item"); done < <(canonical_contract_query approved_globs nul 2>/dev/null || true)
while IFS= read -r -d '' item; do APPROVED_SHARED_FILES+=("$item"); done < <(canonical_contract_query approved_shared_files nul 2>/dev/null || true)

meta_get() {
    printf '%s' "${META[$1]-}"
}

if [[ -n "$FEATURE_ID" ]]; then
    declared_feature_id="$(meta_get feature_id)"
    declared_spec_path="${META[spec_path]-}"
    declared_spec_path="${declared_spec_path//\\//}"
    if [[ "$declared_feature_id" != "$FEATURE_ID" ]]; then
        echo "[ERROR] Spec feature_id '$declared_feature_id' does not match requested feature '$FEATURE_ID'."
        exit 2
    fi
    if [[ "$declared_spec_path" != "$SPEC_RELATIVE_PATH" ]]; then
        echo "[ERROR] Spec spec_path '$declared_spec_path' does not match '$SPEC_RELATIVE_PATH'."
        exit 2
    fi
fi

for key in sdlc_schema planned_files approved_globs; do
    if [[ -z "${META[$key]+present}" ]] && ! canonical_contract_query "$key" json >/dev/null 2>&1; then
        echo "[ERROR] Required workflow metadata '$key' is missing."
        exit 2
    fi
done
if [[ "$(meta_get sdlc_schema)" != '1' ]]; then
    echo "[ERROR] Unsupported sdlc_schema '$(meta_get sdlc_schema)'. Expected '1'."
    exit 2
fi

if [[ -n "$FEATURE_ID" && -f "$REPO_ROOT/docs/specs/$FEATURE_ID/tasks.json" ]]; then
    TASK_GRAPH="$SCRIPT_DIR/task-graph.py"
    [[ -f "$TASK_GRAPH" ]] || { echo "[ERROR] Task graph validator not found: $TASK_GRAPH"; exit 2; }
    PYTHON_EXECUTABLE=''
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then PYTHON_EXECUTABLE="$candidate"; break; fi
    done
    [[ -n "$PYTHON_EXECUTABLE" ]] || { echo '[ERROR] Python 3 is required when a feature tasks.json exists.'; exit 2; }
    set +e
    TASK_SCOPE_OUTPUT="$("$PYTHON_EXECUTABLE" "$TASK_GRAPH" scope --repo-root "$REPO_ROOT" --feature-id "$FEATURE_ID" --spec-path "$SPEC_PATH" --output-format lines 2>&1)"
    TASK_SCOPE_EXIT=$?
    set -e
    if (( TASK_SCOPE_EXIT != 0 )); then
        echo "[PLAN_INVALID] Task graph validation failed: $TASK_SCOPE_OUTPUT"
        exit 2
    fi
    while IFS= read -r task_scope_line; do
        [[ "$task_scope_line" == TASK_FILE:* ]] || continue
        task_path="${task_scope_line#TASK_FILE:}"
        duplicate=0
        for existing_path in "${PLANNED_FILES[@]}"; do
            existing_path="${existing_path//\\//}"
            while [[ "$existing_path" == ./* ]]; do existing_path="${existing_path#./}"; done
            [[ "$existing_path" == "$task_path" ]] && duplicate=1
        done
        (( duplicate == 0 )) && PLANNED_FILES+=("$task_path")
    done <<< "$TASK_SCOPE_OUTPUT"
fi

normalize_path() {
    local value="$1"
    value="${value//\\//}"
    while [[ "$value" == ./* ]]; do
        value="${value#./}"
    done
    printf '%s' "$value"
}

is_glob() {
    [[ "$1" == *'*'* || "$1" == *'?'* || "$1" == *'['* ]]
}

has_valid_glob_approval() {
    local pattern="$1"
    local revision="$(meta_get revision_commit_sha)"
    local record approval_pattern justification approver approval_revision timestamp
    for record in "${APPROVED_GLOBS[@]}"; do
        IFS='|' read -r approval_pattern justification approver approval_revision timestamp <<< "$record"
        approval_pattern="$(normalize_path "$approval_pattern")"
        justification="$(trim_value "${justification-}")"
        approver="$(trim_value "${approver-}")"
        approval_revision="$(trim_value "${approval_revision-}")"
        timestamp="$(trim_value "${timestamp-}")"
        if [[ "$approval_pattern" == "$pattern" && -n "$justification" && -n "$approver" &&
              -n "$approval_revision" && -n "$timestamp" &&
              ( -z "$revision" || "$approval_revision" == "$revision" ) ]]; then
            return 0
        fi
    done
    return 1
}

has_valid_shared_file_approval() {
    local path="$1"
    local revision="$(meta_get revision_commit_sha)"
    local record approval_path justification approver approval_revision timestamp
    for record in "${APPROVED_SHARED_FILES[@]}"; do
        IFS='|' read -r approval_path justification approver approval_revision timestamp <<< "$record"
        approval_path="$(normalize_path "$approval_path")"
        justification="$(trim_value "${justification-}")"
        approver="$(trim_value "${approver-}")"
        approval_revision="$(trim_value "${approval_revision-}")"
        timestamp="$(trim_value "${timestamp-}")"
          approval_revision_matches=1
          if [[ -n "$revision" && "$approval_revision" != "$revision" ]]; then approval_revision_matches=0; fi
          if [[ "$approval_path" == "$path" ]] && ! is_glob "$approval_path" &&
              [[ -n "$justification" && -n "$approver" && -n "$approval_revision" && -n "$timestamp" ]] &&
              (( approval_revision_matches == 1 )); then
            return 0
        fi
    done
    return 1
}

is_shared_project_file() {
    case "$1" in
        .github/sdlc-config.yml|.github/workflows/*)
            return 0
            ;;
    esac
    case "${1##*/}" in
        package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lockb|requirements.txt|pyproject.toml|poetry.lock|Cargo.toml|Cargo.lock|go.mod|go.sum|composer.json|Gemfile|Gemfile.lock|*.sln|*.csproj|*.props|*.targets)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

get_feature_plan_conflicts() {
    local changed_file other_spec other_feature other_plan features_prefix
    [[ -n "$FEATURE_ID" && -d "$REPO_ROOT/docs/specs" ]] || return 0
    features_prefix="$REPO_ROOT/docs/specs/"
    while IFS= read -r -d '' other_spec; do
        other_feature="${other_spec#$features_prefix}"
        other_feature="${other_feature%%/*}"
        [[ "$other_feature" != "$FEATURE_ID" ]] || continue
        while IFS= read -r -d '' other_plan; do
            other_plan="$(normalize_path "$other_plan")"
            [[ -n "$other_plan" ]] || continue
            is_glob "$other_plan" && continue
            for changed_file in "${CHANGED_FILES[@]}"; do
                changed_file="$(normalize_path "$changed_file")"
                [[ "$changed_file" == "$other_plan" ]] && printf '%s\n' "$changed_file (planned by feature '$other_feature')"
            done
        done < <(
            read_canonical_contract "$other_spec" spec-front-matter >/dev/null 2>&1 || exit 0
            canonical_contract_query planned_files nul 2>/dev/null || true
            cleanup_canonical_contract
        )
    done < <(find "$REPO_ROOT/docs/specs" -mindepth 2 -maxdepth 2 -type f -name spec.md -print0 2>/dev/null)
}

glob_to_regex() {
    local pattern="$1"
    local regex='' char next index=0
    while (( index < ${#pattern} )); do
        char="${pattern:index:1}"
        if [[ "$char" == '*' && "${pattern:index+1:1}" == '*' ]]; then
            regex+='.*'
            ((index += 2))
            continue
        fi
        case "$char" in
            '*') regex+='[^/]*' ;;
            '?') regex+='[^/]' ;;
            '.'|'+'|'^'|'$'|'('|')'|'|'|'{'|'}'|'['|']'|'\\') regex+="\\$char" ;;
            *) regex+="$char" ;;
        esac
        ((index += 1))
    done
    printf '^%s$' "$regex"
}

declare -a PLAN_PATTERNS=()
declare -a PLAN_IS_GLOB=()
declare -a PLAN_APPROVED=()
declare -a INVALID_PLAN=()
declare -a UNAPPROVED_GLOBS=()
declare -a INVALID_SHARED_FILES=()

for record in "${APPROVED_SHARED_FILES[@]}"; do
    IFS='|' read -r approval_path justification approver approval_revision timestamp <<< "$record"
    approval_path="$(normalize_path "${approval_path-}")"
    justification="$(trim_value "${justification-}")"
    approver="$(trim_value "${approver-}")"
    approval_revision="$(trim_value "${approval_revision-}")"
    timestamp="$(trim_value "${timestamp-}")"
    invalid_shared=0
    if [[ -z "$approval_path" || "$approval_path" == /* ]]; then invalid_shared=1; fi
    case "$approval_path" in [A-Za-z]:/*|../*|*/../*|.. ) invalid_shared=1 ;; esac
    if is_glob "$approval_path"; then invalid_shared=1; fi
    if [[ -z "$justification" || -z "$approver" || -z "$approval_revision" || -z "$timestamp" ]]; then invalid_shared=1; fi
    if (( invalid_shared == 1 )); then
        INVALID_SHARED_FILES+=("$record (invalid explicit shared-file approval)")
    fi
done

for raw_path in "${PLANNED_FILES[@]}"; do
    path="$(normalize_path "$raw_path")"
    [[ -n "$path" ]] || continue
    if [[ "$path" == /* || "$path" =~ ^[A-Za-z]:/ || "$path" =~ (^|/)\.\.(/|$) ]]; then
        INVALID_PLAN+=("$path (path must be relative)")
        continue
    fi
    if [[ "$path" == */ ]]; then
        INVALID_PLAN+=("$path (directory entries are not allowed; list exact files)")
        continue
    fi
    PLAN_PATTERNS+=("$path")
    if is_glob "$path"; then
        PLAN_IS_GLOB+=(1)
        if has_valid_glob_approval "$path"; then
            PLAN_APPROVED+=(1)
        else
            PLAN_APPROVED+=(0)
            UNAPPROVED_GLOBS+=("$path")
        fi
    else
        PLAN_IS_GLOB+=(0)
        PLAN_APPROVED+=(1)
    fi
done

echo '=== Scope Audit ==='
[[ -n "$FEATURE_ID" ]] && echo "Feature: $FEATURE_ID"
echo "Planned files: ${#PLAN_PATTERNS[@]}"
echo "Base ref: $BASE_REF"
echo
if (( ${#INVALID_PLAN[@]} > 0 )); then
    echo "[PLAN_INVALID] (${#INVALID_PLAN[@]})"
    printf '  !!  %s\n' "${INVALID_PLAN[@]}"
    echo
fi
if (( ${#UNAPPROVED_GLOBS[@]} > 0 )); then
    echo "[PLAN_INVALID] (${#UNAPPROVED_GLOBS[@]}) unapproved glob patterns"
    for pattern in "${UNAPPROVED_GLOBS[@]}"; do
        echo "  !!  $pattern requires an approved_globs record"
    done
    echo
fi
if (( ${#INVALID_SHARED_FILES[@]} > 0 )); then
    echo "[PLAN_INVALID] (${#INVALID_SHARED_FILES[@]}) invalid shared-file approvals"
    printf '  !!  %s\n' "${INVALID_SHARED_FILES[@]}"
    echo
fi

declare -a CHANGED_FILES=()
pushd "$REPO_ROOT" >/dev/null
if [[ "$BASE_REF" == 'staged' ]]; then
    mapfile -t CHANGED_FILES < <(git diff --cached --name-only 2>/dev/null | tr -d '\r' | sort -u || true)
elif [[ "$BASE_REF" == 'HEAD' ]]; then
    mapfile -t CHANGED_FILES < <({ git diff --cached --name-only 2>/dev/null; git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | tr -d '\r' | sort -u || true)
else
    mapfile -t CHANGED_FILES < <(git diff --name-only "$BASE_REF" 2>/dev/null | tr -d '\r' | sort -u || true)
fi
popd >/dev/null

FEATURE_CONFLICTS=()
while IFS= read -r conflict; do
    [[ -n "$conflict" ]] && FEATURE_CONFLICTS+=("$conflict")
done < <(get_feature_plan_conflicts | sort -u)

if (( ${#CHANGED_FILES[@]} == 0 )); then
    echo '[INFO] No changed files detected.'
else
    echo "Changed files (${#CHANGED_FILES[@]}):"
    printf '  %s\n' "${CHANGED_FILES[@]}"
    echo
fi

declare -a WORKFLOW_CHANGES=()
declare -a IN_SCOPE=()
declare -a SHARED_SCOPE=()
declare -a SCOPE_CREEP=()

for file in "${CHANGED_FILES[@]}"; do
    file="$(normalize_path "$file")"
    is_feature_workflow=0
    if [[ -n "$FEATURE_ID" && ( "$file" == "$SPEC_RELATIVE_PATH" || "$file" == ".sdlc/evidence/$FEATURE_ID" || "$file" == ".sdlc/evidence/$FEATURE_ID"/* ) ]]; then
        is_feature_workflow=1
    fi
    is_legacy_workflow=0
    if [[ -z "$FEATURE_ID" && ( "$file" == 'docs/spec.md' || "$file" == '.sdlc' || "$file" == .sdlc/* ) ]]; then
        is_legacy_workflow=1
    fi
    if (( is_feature_workflow == 1 || is_legacy_workflow == 1 )); then
        WORKFLOW_CHANGES+=("$file")
        continue
    fi
    conflict_found=0
    for conflict in "${FEATURE_CONFLICTS[@]}"; do
        [[ "$conflict" == "$file ("* ]] && conflict_found=1
    done
    (( conflict_found == 1 )) && continue
    if has_valid_shared_file_approval "$file"; then
        SHARED_SCOPE+=("$file")
        continue
    fi
    if is_shared_project_file "$file"; then
        SCOPE_CREEP+=("$file (shared file requires an approved_shared_files record)")
        continue
    fi
    matched=0
    for ((index = 0; index < ${#PLAN_PATTERNS[@]}; index++)); do
        pattern="${PLAN_PATTERNS[$index]}"
        if (( ${PLAN_IS_GLOB[$index]} == 1 )); then
            if (( ${PLAN_APPROVED[$index]} == 1 )) && [[ "$file" =~ $(glob_to_regex "$pattern") ]]; then
                matched=1
                break
            fi
        elif [[ "$file" == "$pattern" ]]; then
            matched=1
            break
        fi
    done
    if (( matched == 1 )); then
        IN_SCOPE+=("$file")
    else
        SCOPE_CREEP+=("$file")
    fi
done

declare -a MISSING=()
for ((index = 0; index < ${#PLAN_PATTERNS[@]}; index++)); do
    (( ${PLAN_IS_GLOB[$index]} == 1 )) && continue
    if [[ ! -f "$REPO_ROOT/${PLAN_PATTERNS[$index]}" ]]; then
        MISSING+=("${PLAN_PATTERNS[$index]}")
    fi
done

echo '=== Results ==='
echo
if (( ${#WORKFLOW_CHANGES[@]} > 0 )); then
    echo "[WORKFLOW] (${#WORKFLOW_CHANGES[@]} files excluded from product scope)"
    printf '  OK  %s\n' "${WORKFLOW_CHANGES[@]}"
    echo
fi
if (( ${#IN_SCOPE[@]} > 0 )); then
    echo "[IN_SCOPE] (${#IN_SCOPE[@]} files)"
    printf '  OK  %s\n' "${IN_SCOPE[@]}"
    echo
fi
if (( ${#SCOPE_CREEP[@]} > 0 )); then
    echo "[SCOPE_CREEP] (${#SCOPE_CREEP[@]} files) - changed files not in planned_files:"
    printf '  !!  %s\n' "${SCOPE_CREEP[@]}"
    echo
fi
if (( ${#SHARED_SCOPE[@]} > 0 )); then
    echo "[SHARED_SCOPE] (${#SHARED_SCOPE[@]} files) - explicit shared-file approval:"
    printf '  OK  %s\n' "${SHARED_SCOPE[@]}"
    echo
fi
if (( ${#FEATURE_CONFLICTS[@]} > 0 )); then
    echo "[CONFLICT] (${#FEATURE_CONFLICTS[@]} files) - another feature claims the changed file:"
    printf '  !!  %s\n' "${FEATURE_CONFLICTS[@]}"
    echo
fi
if (( ${#MISSING[@]} > 0 )); then
    echo "[MISSING] (${#MISSING[@]} files) - exact planned files not present:"
    printf '  ??  %s\n' "${MISSING[@]}"
    echo
fi
if (( ${#INVALID_PLAN[@]} == 0 && ${#UNAPPROVED_GLOBS[@]} == 0 && ${#SCOPE_CREEP[@]} == 0 && ${#MISSING[@]} == 0 )); then
    echo '[PASS] All changes are within the approved planned scope.'
fi

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '"%s"' "$value"
}
json_array() {
    local first=1 value
    printf '['
    for value in "$@"; do
        (( first == 0 )) && printf ','
        json_escape "$value"
        first=0
    done
    printf ']'
}

clean=true
if (( ${#INVALID_PLAN[@]} > 0 || ${#UNAPPROVED_GLOBS[@]} > 0 || ${#INVALID_SHARED_FILES[@]} > 0 || ${#FEATURE_CONFLICTS[@]} > 0 || ${#SCOPE_CREEP[@]} > 0 || ${#MISSING[@]} > 0 )); then
    clean=false
fi
echo '--- JSON Summary ---'
printf '{"planned":%d,"changed":%d,"workflow":' "${#PLAN_PATTERNS[@]}" "${#CHANGED_FILES[@]}"
json_array "${WORKFLOW_CHANGES[@]}"
printf '%s' ',"in_scope":'
json_array "${IN_SCOPE[@]}"
printf '%s' ',"shared_scope":'
json_array "${SHARED_SCOPE[@]}"
printf '%s' ',"scope_creep":'
json_array "${SCOPE_CREEP[@]}"
printf '%s' ',"conflicts":'
json_array "${FEATURE_CONFLICTS[@]}"
printf '%s' ',"invalid_shared_files":'
json_array "${INVALID_SHARED_FILES[@]}"
printf '%s' ',"missing":'
json_array "${MISSING[@]}"
printf '%s' ',"invalid_plan":'
json_array "${INVALID_PLAN[@]}"
printf '%s' ',"unapproved_globs":'
json_array "${UNAPPROVED_GLOBS[@]}"
printf ',"clean":%s}\n' "$clean"

if (( ${#INVALID_PLAN[@]} > 0 || ${#UNAPPROVED_GLOBS[@]} > 0 || ${#INVALID_SHARED_FILES[@]} > 0 || ${#FEATURE_CONFLICTS[@]} > 0 )); then
    exit 2
fi
if (( ${#SCOPE_CREEP[@]} > 0 || ${#MISSING[@]} > 0 )); then
    exit 1
fi
exit 0
